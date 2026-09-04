//
//  SpeechEnhancer.swift
//  Kurn
//
//  Streaming GTCRN noise suppression for the enhanced listening copy. The
//  model is tiny enough to process complete meetings, while the renderer still
//  treats a missing model as a supported DSP-only configuration.
//

import CoreML
import Foundation

/// Removes background noise from mono 16 kHz speech.
protocol SpeechEnhancing: Sendable {
    /// Enhanced samples, or `nil` when no model is available.
    func enhance(samples: [Float]) async -> [Float]?

    /// Opens a blockwise render. Model caches and STFT overlap carry across all
    /// calls made under the returned identifier; `nil` means no model.
    func beginStream() async -> UUID?

    /// Enhances one block. A final call flushes the STFT tail and returns a
    /// stream with exactly the same number of samples as the input.
    func enhance(samples: [Float], streamID: UUID, isFinal: Bool) async -> [Float]?

    func endStream(_ streamID: UUID) async

    /// File alignment offset at `sampleRate`. GTCRN's streaming overlap-add is
    /// emitted already aligned, so the concrete implementation returns zero.
    func latencyFrames(at sampleRate: Double) async -> Int?
}

/// One recurrent tensor carried between GTCRN frames.
struct SpeechEnhancerStateConfig: Codable, Sendable, Equatable {
    var input: String
    var output: String
    var shape: [Int]

    var elementCount: Int {
        shape.reduce(1, *)
    }
}

/// Interface of the converted GTCRN model, emitted by `Tools/gtcrn/convert.py`.
struct SpeechEnhancerModelConfig: Codable, Sendable, Equatable {
    var modelName: String
    var sampleRate: Double
    var frameSize: Int
    var hopSize: Int
    var binCount: Int
    var spectrumInput: String
    var spectrumOutput: String
    var states: [SpeechEnhancerStateConfig]

    static let resourceName = "gtcrn"

    static func bundled(in bundle: Bundle = .main) -> SpeechEnhancerModelConfig? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SpeechEnhancerModelConfig.self, from: data) else {
            AppLog.transcription.atError.error("enhance: found \(resourceName, privacy: .public).json but could not decode it")
            return nil
        }
        return config
    }
}

/// Loads the converted GTCRN model once and owns all active streaming states.
actor SpeechEnhancer: SpeechEnhancing {
    static let shared = SpeechEnhancer()

    private let bundle: Bundle
    private var resolved = false
    private var config: SpeechEnhancerModelConfig?
    private var model: MLModel?
    private var streams: [UUID: StreamState] = [:]

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func isModelAvailable() -> Bool {
        resolveModel() != nil
    }

    func enhance(samples: [Float]) async -> [Float]? {
        guard let streamID = beginStream() else { return nil }
        let output = enhance(samples: samples, streamID: streamID, isFinal: true)
        streams.removeValue(forKey: streamID)
        return output
    }

    func beginStream() -> UUID? {
        guard let config = resolveConfig(), let model = resolveModel() else { return nil }
        guard Self.isValid(config: config) else {
            AppLog.recorder.atError.error("enhance: invalid GTCRN config")
            return nil
        }
        do {
            let streamID = UUID()
            streams[streamID] = try StreamState(config: config, model: model)
            return streamID
        } catch {
            AppLog.recorder.atError.error("enhance: could not initialize GTCRN tensors code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func enhance(samples: [Float], streamID: UUID, isFinal: Bool) -> [Float]? {
        guard var stream = streams.removeValue(forKey: streamID) else { return nil }
        do {
            let output = try stream.append(samples, isFinal: isFinal)
            if !isFinal {
                streams[streamID] = stream
            }
            return output
        } catch {
            AppLog.recorder.atError.error("enhance: GTCRN inference failed, using DSP only code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func endStream(_ streamID: UUID) {
        streams.removeValue(forKey: streamID)
    }

    func latencyFrames(at sampleRate: Double) -> Int? {
        guard resolveConfig() != nil, resolveModel() != nil else { return nil }
        return 0
    }

    private func resolveConfig() -> SpeechEnhancerModelConfig? {
        if !resolved {
            resolved = true
            config = SpeechEnhancerModelConfig.bundled(in: bundle)
            if config == nil {
                AppLog.recorder.atNotice.notice("enhance: no GTCRN model installed, using DSP only")
            }
        }
        return config
    }

    private func resolveModel() -> MLModel? {
        guard model == nil, let config = resolveConfig() else { return model }
        guard let url = bundle.url(forResource: config.modelName, withExtension: "mlmodelc") else {
            AppLog.recorder.atNotice.notice("enhance: GTCRN config is present but the compiled model is missing")
            return nil
        }
        do {
            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = .all
            model = try MLModel(contentsOf: url, configuration: modelConfiguration)
        } catch {
            AppLog.recorder.atError.error("enhance: could not load GTCRN code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        }
        return model
    }

    private static func isValid(config: SpeechEnhancerModelConfig) -> Bool {
        config.sampleRate > 0
            && config.frameSize > 0
            && config.hopSize > 0
            && config.hopSize <= config.frameSize
            && config.binCount == config.frameSize / 2 + 1
            && !config.spectrumInput.isEmpty
            && !config.spectrumOutput.isEmpty
            && !config.states.isEmpty
            && config.states.allSatisfy {
                !$0.input.isEmpty
                    && !$0.output.isEmpty
                    && !$0.shape.isEmpty
                    && $0.shape.allSatisfy { $0 > 0 }
            }
    }
}

/// Mirrors the official GTCRN online STFT contract: every input hop shifts a
/// zero-initialized analysis window, and the first synthesized hop is retained
/// until it can overlap with the next frame. The final zero hop flushes that
/// overlap without introducing leading silence in the output file.
private struct StreamState {
    let config: SpeechEnhancerModelConfig
    let model: MLModel
    let stft: STFT
    var spectrum: MLMultiArray
    var states: [MLMultiArray]
    var pendingInput: [Float] = []
    var pendingOffset = 0
    var analysisBuffer: [Float]
    var overlap: [Float]
    var real: [Float]
    var imaginary: [Float]
    var started = false
    var totalInputSamples = 0
    var totalOutputSamples = 0

    init(config: SpeechEnhancerModelConfig, model: MLModel) throws {
        self.config = config
        self.model = model
        self.stft = STFT(
            frameSize: config.frameSize,
            hopSize: config.hopSize,
            windowMode: .squareRootHann
        )
        self.spectrum = try MLMultiArray(
            shape: [1, NSNumber(value: config.binCount), 1, 2],
            dataType: .float32
        )
        self.states = try config.states.map { state in
            let tensor = try MLMultiArray(
                shape: state.shape.map(NSNumber.init(value:)),
                dataType: .float32
            )
            tensor.dataPointer.initializeMemory(
                as: Float.self,
                repeating: 0,
                count: state.elementCount
            )
            return tensor
        }
        self.analysisBuffer = [Float](repeating: 0, count: config.frameSize)
        self.overlap = [Float](repeating: 0, count: config.frameSize)
        self.real = [Float](repeating: 0, count: config.binCount)
        self.imaginary = [Float](repeating: 0, count: config.binCount)
    }

    mutating func append(_ samples: [Float], isFinal: Bool) throws -> [Float] {
        pendingInput.append(contentsOf: samples)
        totalInputSamples += samples.count
        var output: [Float] = []

        while pendingInput.count - pendingOffset >= config.hopSize {
            try processHop(input: pendingInput, offset: pendingOffset, output: &output)
            pendingOffset += config.hopSize
        }

        if isFinal {
            let remainingInput = pendingInput.count - pendingOffset
            if remainingInput > 0 {
                var padded = [Float](repeating: 0, count: config.hopSize)
                for index in 0..<remainingInput {
                    padded[index] = pendingInput[pendingOffset + index]
                }
                try processHop(input: padded, offset: 0, output: &output)
            }
            if started {
                let zeros = [Float](repeating: 0, count: config.hopSize)
                try processHop(input: zeros, offset: 0, output: &output)
            }

            let wanted = max(0, totalInputSamples - totalOutputSamples)
            if output.count > wanted {
                output.removeLast(output.count - wanted)
            }
        } else {
            compactPendingInputIfNeeded()
        }

        totalOutputSamples += output.count
        return output
    }

    private mutating func processHop(
        input: [Float],
        offset: Int,
        output: inout [Float]
    ) throws {
        let retained = config.frameSize - config.hopSize
        for index in 0..<retained {
            analysisBuffer[index] = analysisBuffer[index + config.hopSize]
        }
        for index in 0..<config.hopSize {
            analysisBuffer[retained + index] = input[offset + index]
        }

        stft.forward(
            samples: analysisBuffer,
            frameStart: 0,
            real: &real,
            imag: &imaginary,
            offset: 0
        )
        try runModel()
        let frame = stft.inverse(real: real, imag: imaginary, offset: 0)

        for index in 0..<retained {
            overlap[index] = overlap[index + config.hopSize]
        }
        for index in retained..<config.frameSize {
            overlap[index] = 0
        }
        for index in 0..<config.frameSize {
            overlap[index] += frame[index]
        }

        if started {
            output.append(contentsOf: overlap.prefix(config.hopSize))
        } else {
            started = true
        }
    }

    private mutating func runModel() throws {
        let spectrumValues = spectrum.dataPointer.bindMemory(
            to: Float.self,
            capacity: config.binCount * 2
        )
        for bin in 0..<config.binCount {
            spectrumValues[bin * 2] = real[bin]
            spectrumValues[bin * 2 + 1] = imaginary[bin]
        }

        try autoreleasepool {
            var inputs: [String: Any] = [
                config.spectrumInput: MLFeatureValue(multiArray: spectrum)
            ]
            for (stateConfig, tensor) in zip(config.states, states) {
                inputs[stateConfig.input] = MLFeatureValue(multiArray: tensor)
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
            let prediction = try model.prediction(from: provider)
            guard let enhanced = prediction.featureValue(
                for: config.spectrumOutput
            )?.multiArrayValue,
            enhanced.count == config.binCount * 2 else {
                throw EnhancementInferenceError.invalidOutput
            }

            let enhancedValues = enhanced.dataPointer.bindMemory(
                to: Float.self,
                capacity: config.binCount * 2
            )
            for bin in 0..<config.binCount {
                real[bin] = enhancedValues[bin * 2]
                imaginary[bin] = enhancedValues[bin * 2 + 1]
            }

            for index in config.states.indices {
                let stateConfig = config.states[index]
                guard let next = prediction.featureValue(
                    for: stateConfig.output
                )?.multiArrayValue,
                next.count == stateConfig.elementCount else {
                    throw EnhancementInferenceError.invalidOutput
                }
                states[index].dataPointer.assumingMemoryBound(to: Float.self).update(
                    from: next.dataPointer.assumingMemoryBound(to: Float.self),
                    count: stateConfig.elementCount
                )
            }
        }
    }

    private mutating func compactPendingInputIfNeeded() {
        guard pendingOffset >= 8_192 else { return }
        pendingInput.removeFirst(pendingOffset)
        pendingOffset = 0
    }
}

private enum EnhancementInferenceError: Error {
    case invalidOutput
}

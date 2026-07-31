//
//  SpeechEnhancer.swift
//  Kurn
//
//  Seam for the neural denoise stage of the enhanced listening copy.
//
//  The stage is optional by design, and the renderer treats its absence as normal
//  rather than as a failure. Two reasons:
//
//  1. The model is converted from DPDFNet's ONNX release by `Tools/dpdfnet/`,
//     which needs macOS and `coremltools`. Until someone runs it and drops the
//     `.mlpackage` into the bundle, the app must still build, test and work.
//  2. Denoising is the *smaller* half of what makes a far-table voice audible.
//     It removes the noise around a quiet talker without making the talker any
//     louder — that is the compressor's and the loudness normalization's job.
//     A DSP-only enhanced copy is already worth listening to.
//
//  So `SpeechEnhancer.shared.enhance` returning `nil` is a supported outcome, not
//  an error path. `PlaybackEnhancementRenderer` responds by running its existing
//  DSP chain directly on the source.
//

import Accelerate
import CoreML
import Foundation

/// Removes background noise from mono 16 kHz speech.
///
/// The blockwise half of this protocol is what the renderer actually calls, and
/// it is here rather than on the concrete type so a test can substitute a known
/// signal for the model's output. Without that seam the only assertable part of
/// the neural pass is `PlaybackMix`'s pointer arithmetic — which is given the
/// latency to compensate rather than deriving it, so it cannot catch a wrong
/// `latencyFrames`, the one number a mistake in would comb-filter every
/// enhanced copy.
protocol SpeechEnhancing: Sendable {
    /// Enhanced samples, or `nil` when no model is available. Never throws: a
    /// missing or broken model degrades the render, it does not fail it.
    func enhance(samples: [Float]) async -> [Float]?

    /// Opens a blockwise render. State and STFT overlap carry across the calls
    /// made under the returned identifier; `nil` means no model.
    func beginStream() async -> UUID?

    /// Enhances one block of the stream. The first call also emits the leading
    /// latency, which `latencyFrames(at:)` describes and the mix removes.
    func enhance(samples: [Float], streamID: UUID, isFinal: Bool) async -> [Float]?

    func endStream(_ streamID: UUID) async

    /// Frames of leading silence the output carries, expressed at `sampleRate`
    /// rather than the model's — the mix happens after the resample back up.
    func latencyFrames(at sampleRate: Double) async -> Int?
}

/// Description of a converted model, emitted alongside the `.mlpackage` by
/// `Tools/dpdfnet/convert.py`.
///
/// The tensor names, bin count and state shape are *discovered* from the ONNX
/// graph at conversion time and written here, rather than hardcoded in Swift from
/// reading the model's documentation. Guessing them would produce a model that
/// loads and runs and returns plausible-sounding garbage — the same class of
/// silent failure the WPE port guards against with a parity test.
struct SpeechEnhancerModelConfig: Codable, Sendable, Equatable {
    /// Base name of the `.mlmodelc` in the app bundle.
    var modelName: String
    /// Sample rate the model was trained at. The renderer resamples to this.
    var sampleRate: Double
    /// STFT window length in samples.
    var frameSize: Int
    /// STFT hop in samples.
    var hopSize: Int
    /// Frequency bins the graph consumes and produces (`frameSize / 2 + 1`).
    var binCount: Int
    /// Flattened size of the recurrent state carried between frames.
    var stateSize: Int
    /// Input tensor names, in the order the graph declares them.
    var spectrumInput: String
    var stateInput: String
    /// Output tensor names.
    var spectrumOutput: String
    var stateOutput: String

    /// Name of the JSON sidecar in the bundle.
    static let resourceName = "dpdfnet"

    /// Load the config shipped next to the model, or `nil` when the conversion
    /// has not been run for this build.
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

/// Loads the converted DPDFNet model once and runs it frame by frame.
///
/// `actor` with a shared instance, mirroring `FluidAudioModelStore`: CoreML
/// compiles its artifacts on first load, and two concurrent renders must not pay
/// that twice or race each other's state.
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

    /// Whether a model is installed. Lets the UI explain that enhancement is
    /// running DSP-only rather than silently doing less than the user expects.
    func isModelAvailable() -> Bool {
        resolveModel() != nil
    }

    func enhance(samples: [Float]) async -> [Float]? {
        guard let streamID = beginStream() else { return nil }
        let output = enhance(samples: samples, streamID: streamID, isFinal: true)
        streams.removeValue(forKey: streamID)
        return output
    }

    /// Starts a blockwise render. The renderer uses this instead of decoding a
    /// whole recording into one `[Float]`; state and overlap carry across calls.
    func beginStream() -> UUID? {
        guard let config = resolveConfig(), let model = resolveModel() else { return nil }
        guard Self.isValid(config: config) else {
            AppLog.recorder.atError.error("enhance: invalid DPDFNet config")
            return nil
        }
        do {
            let streamID = UUID()
            streams[streamID] = try StreamState(config: config, model: model)
            return streamID
        } catch {
            AppLog.recorder.atError.error("enhance: could not initialize model tensors: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Enhances one decoded block. Output includes one frame of leading latency;
    /// `PlaybackEnhancementRenderer` removes it before the dry/wet sum.
    func enhance(samples: [Float], streamID: UUID, isFinal: Bool) -> [Float]? {
        guard var stream = streams.removeValue(forKey: streamID) else { return nil }
        do {
            let output = try stream.append(samples, isFinal: isFinal)
            if !isFinal {
                streams[streamID] = stream
            }
            return output
        } catch {
            AppLog.recorder.atError.error("enhance: inference failed, using DSP only: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func endStream(_ streamID: UUID) {
        streams.removeValue(forKey: streamID)
    }

    func latencyFrames(at sampleRate: Double) -> Int? {
        guard let config = resolveConfig(), resolveModel() != nil else { return nil }
        return Int((Double(config.frameSize) * sampleRate / config.sampleRate).rounded())
    }

    private func resolveConfig() -> SpeechEnhancerModelConfig? {
        if !resolved {
            resolved = true
            config = SpeechEnhancerModelConfig.bundled(in: bundle)
            if config == nil {
                AppLog.recorder.atNotice.notice("enhance: no speech-enhancement model installed, using DSP only")
            }
        }
        return config
    }

    private func resolveModel() -> MLModel? {
        guard model == nil, let config = resolveConfig() else { return model }
        guard let url = bundle.url(forResource: config.modelName, withExtension: "mlmodelc") else {
            AppLog.recorder.atNotice.notice("enhance: DPDFNet config is present but the compiled model is missing")
            return nil
        }
        do {
            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = .all
            model = try MLModel(contentsOf: url, configuration: modelConfiguration)
        } catch {
            AppLog.recorder.atError.error("enhance: could not load DPDFNet: \(error.localizedDescription, privacy: .public)")
        }
        return model
    }

    private static func isValid(config: SpeechEnhancerModelConfig) -> Bool {
        config.sampleRate > 0
            && config.frameSize > 0
            && config.hopSize > 0
            && config.binCount == config.frameSize / 2 + 1
            && config.stateSize > 0
    }
}

private struct StreamState {
    let config: SpeechEnhancerModelConfig
    let model: MLModel
    let stft: STFT
    var spectrum: MLMultiArray
    var recurrentState: MLMultiArray
    var input: [Float] = []
    var inputBase = 0
    var nextFrameStart = 0
    var receivedCount = 0
    var alignedEmittedCount = 0
    var latencyEmitted = false
    var overlap: [Float]
    var real: [Float]
    var imaginary: [Float]

    init(config: SpeechEnhancerModelConfig, model: MLModel) throws {
        self.config = config
        self.model = model
        self.stft = STFT(frameSize: config.frameSize, hopSize: config.hopSize)
        self.spectrum = try MLMultiArray(
            shape: [1, 1, NSNumber(value: config.binCount), 2],
            dataType: .float32
        )
        self.recurrentState = try MLMultiArray(
            shape: [NSNumber(value: config.stateSize)],
            dataType: .float32
        )
        self.overlap = [Float](repeating: 0, count: config.frameSize)
        self.real = [Float](repeating: 0, count: config.binCount)
        self.imaginary = [Float](repeating: 0, count: config.binCount)
        recurrentState.dataPointer.initializeMemory(
            as: Float.self,
            repeating: 0,
            count: config.stateSize
        )
    }

    mutating func append(_ samples: [Float], isFinal: Bool) throws -> [Float] {
        input.append(contentsOf: samples)
        receivedCount += samples.count
        var output: [Float] = []
        if !latencyEmitted {
            output.append(contentsOf: repeatElement(0, count: config.frameSize))
            latencyEmitted = true
        }

        while shouldProcessFrame(isFinal: isFinal) {
            let localStart = nextFrameStart - inputBase
            let missing = localStart + config.frameSize - input.count
            if missing > 0 {
                input.append(contentsOf: repeatElement(0, count: missing))
            }
            try processFrame(localStart: localStart)
            output.append(contentsOf: overlap.prefix(config.hopSize))
            shiftOverlap()
            nextFrameStart += config.hopSize
            alignedEmittedCount += config.hopSize
        }

        if isFinal {
            let excess = max(0, alignedEmittedCount - receivedCount)
            if excess > 0 { output.removeLast(min(excess, output.count)) }
        } else {
            compactInputIfNeeded()
        }
        return output
    }

    private func shouldProcessFrame(isFinal: Bool) -> Bool {
        if isFinal {
            return nextFrameStart < receivedCount
        }
        return nextFrameStart + config.frameSize <= receivedCount
    }

    private mutating func processFrame(localStart: Int) throws {
        stft.forward(
            samples: input,
            frameStart: localStart,
            real: &real,
            imag: &imaginary,
            offset: 0
        )
        let values = spectrum.dataPointer.bindMemory(
            to: Float.self,
            capacity: config.binCount * 2
        )
        for bin in 0..<config.binCount {
            values[bin * 2] = real[bin]
            values[bin * 2 + 1] = imaginary[bin]
        }

        // CoreML's prediction objects and feature providers own autoreleased
        // IOSurface-backed buffers on the Neural Engine. A long recording runs
        // tens of thousands of frames on one cooperative-pool thread, which has
        // no useful outer autorelease-pool boundary. Without draining here the
        // process eventually reaches the per-client IOSurface limit and CoreML
        // raises an NSException. Copying the returned recurrent state into the
        // existing input tensor also lets its output surface die with this pool.
        try autoreleasepool {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                config.spectrumInput: MLFeatureValue(multiArray: spectrum),
                config.stateInput: MLFeatureValue(multiArray: recurrentState)
            ])
            let prediction = try model.prediction(from: provider)
            guard let enhanced = prediction.featureValue(
                for: config.spectrumOutput
            )?.multiArrayValue,
            let nextState = prediction.featureValue(
                for: config.stateOutput
            )?.multiArrayValue,
            enhanced.count == config.binCount * 2,
            nextState.count == config.stateSize else {
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
            let nextStateValues = nextState.dataPointer.bindMemory(
                to: Float.self,
                capacity: config.stateSize
            )
            recurrentState.dataPointer.assumingMemoryBound(to: Float.self).update(
                from: nextStateValues,
                count: config.stateSize
            )
        }
        let frame = stft.inverse(real: real, imag: imaginary, offset: 0)
        for index in 0..<config.frameSize {
            overlap[index] += frame[index]
        }
    }

    private mutating func shiftOverlap() {
        let remaining = config.frameSize - config.hopSize
        for index in 0..<remaining {
            overlap[index] = overlap[index + config.hopSize]
        }
        for index in remaining..<config.frameSize {
            overlap[index] = 0
        }
    }

    private mutating func compactInputIfNeeded() {
        let consumed = nextFrameStart - inputBase
        guard consumed >= 8_192 else { return }
        input.removeFirst(consumed)
        inputBase = nextFrameStart
    }
}

private enum EnhancementInferenceError: Error {
    case invalidOutput
}

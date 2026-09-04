//
//  PlaybackEnhancementNeuralPass.swift
//  Kurn
//
//  File-backed neural decode/enhance/resample/mix pass. Every intermediate is
//  Float32 PCM, so the source AAC is decoded exactly once through
//  OfflineAudioRenderer and memory remains bounded by one small audio block.
//

import AudioToolbox
import KurnCore
import AVFoundation
import Foundation

extension PlaybackEnhancementRenderer {
    func renderNeuralMix(
        from sourceURL: URL,
        failure: AppError,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL? {
        onProgress?(0)
        try Task.checkCancellation()
        guard let streamID = await enhancer.beginStream(),
              let latencyFrames = await enhancer.latencyFrames(
                at: Self.outputSampleRate
              ) else {
            onProgress?(1)
            return nil
        }

        let decodedURL = Self.neuralTempURL(label: "decode16")
        let wet16URL = Self.neuralTempURL(label: "wet16")
        let wet24URL = Self.neuralTempURL(label: "wet24")
        let mixedURL = Self.neuralTempURL(label: "mix24")
        var keepMixed = false
        defer {
            try? FileManager.default.removeItem(at: decodedURL)
            try? FileManager.default.removeItem(at: wet16URL)
            try? FileManager.default.removeItem(at: wet24URL)
            if !keepMixed { try? FileManager.default.removeItem(at: mixedURL) }
        }

        do {
            try await Self.decodePCM(
                sourceURL,
                to: decodedURL,
                sampleRate: 16_000,
                stage: NeuralStage(
                    failure: failure,
                    logLabel: "enhance.neural.decode",
                    onProgress: { onProgress?(0.10 * $0) }
                )
            )
            try await Self.enhancePCM(
                decodedURL,
                to: wet16URL,
                enhancer: enhancer,
                streamID: streamID,
                stage: NeuralStage(
                    failure: failure,
                    logLabel: "enhance.neural.inference",
                    onProgress: { onProgress?(0.10 + 0.65 * $0) }
                )
            )
            try await Self.decodePCM(
                wet16URL,
                to: wet24URL,
                sampleRate: Self.outputSampleRate,
                stage: NeuralStage(
                    failure: failure,
                    logLabel: "enhance.neural.resample",
                    onProgress: { onProgress?(0.75 + 0.05 * $0) }
                )
            )
            try await mixPCM(
                dryURL: sourceURL,
                wetURL: wet24URL,
                to: mixedURL,
                latencyFrames: latencyFrames,
                stage: NeuralStage(
                    failure: failure,
                    logLabel: "enhance.neural.mix",
                    onProgress: { onProgress?(0.80 + 0.20 * $0) }
                )
            )
            keepMixed = true
            onProgress?(1)
            await enhancer.endStream(streamID)
            return mixedURL
        } catch {
            await enhancer.endStream(streamID)
            if error is CancellationError { throw error }
            try ResourceGuard.rethrowIfResourceFailure(error)
            AppLog.recorder.atError.error("enhance: neural pre-pass failed, using DSP only code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            onProgress?(1)
            return nil
        }
    }

    private static func decodePCM(
        _ sourceURL: URL,
        to outputURL: URL,
        sampleRate: Double,
        stage: NeuralStage
    ) async throws {
        guard let format = OfflineAudioRenderer.monoFormat(sampleRate: sampleRate) else {
            throw stage.failure
        }
        var outputFile: AVAudioFile? = try makePCMFile(at: outputURL, sampleRate: sampleRate)
        let renderer = OfflineAudioRenderer(
            outputFormat: format,
            failure: stage.failure,
            logLabel: stage.logLabel
        )
        try await renderer.render(url: sourceURL, onProgress: stage.onProgress) { buffer in
            try Task.checkCancellation()
            try outputFile?.write(from: buffer)
        }
        outputFile = nil
    }

    private static func enhancePCM(
        _ inputURL: URL,
        to outputURL: URL,
        enhancer: any SpeechEnhancing,
        streamID: UUID,
        stage: NeuralStage
    ) async throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        var outputFile: AVAudioFile? = try makePCMFile(at: outputURL, sampleRate: 16_000)
        let blockFrames: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: blockFrames
        ) else {
            throw stage.failure
        }

        let started = Date()
        var lastReportedPercent = -1
        while inputFile.framePosition < inputFile.length {
            try Task.checkCancellation()
            try inputFile.read(into: buffer, frameCount: blockFrames)
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let samples = Array(
                UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
            )
            let isFinal = inputFile.framePosition >= inputFile.length
            guard let enhanced = await enhancer.enhance(
                samples: samples,
                streamID: streamID,
                isFinal: isFinal
            ) else {
                throw NeuralPassError.inferenceFailed
            }
            try write(enhanced, to: outputFile, failure: stage.failure)

            let fraction = Double(inputFile.framePosition) / Double(max(1, inputFile.length))
            let percent = min(100, max(0, Int(fraction * 100)))
            guard percent > lastReportedPercent else { continue }
            lastReportedPercent = percent
            stage.onProgress?(Double(percent) / 100)
            if percent == 1 || percent == 100 || percent / 10 > (percent - 1) / 10 {
                let elapsed = Date().timeIntervalSince(started)
                let remaining = percent > 0 ? elapsed * Double(100 - percent) / Double(percent) : 0
                AppLog.recorder.atInfo.info("enhance.neural.inference: \(percent, privacy: .public)% elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s eta≈\(String(format: "%.1f", remaining), privacy: .public)s")
            }
        }
        outputFile = nil
    }

    private func mixPCM(
        dryURL: URL,
        wetURL: URL,
        to outputURL: URL,
        latencyFrames: Int,
        stage: NeuralStage
    ) async throws {
        guard let format = OfflineAudioRenderer.monoFormat(
            sampleRate: Self.outputSampleRate
        ) else {
            throw stage.failure
        }
        let wetFile = try AVAudioFile(forReading: wetURL)
        wetFile.framePosition = min(AVAudioFramePosition(latencyFrames), wetFile.length)
        guard let wetBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_096
        ) else {
            throw stage.failure
        }
        var outputFile: AVAudioFile? = try Self.makePCMFile(
            at: outputURL,
            sampleRate: Self.outputSampleRate
        )
        var mixed = [Float](repeating: 0, count: 4_096)
        var shortfall = 0
        let renderer = OfflineAudioRenderer(
            outputFormat: format,
            failure: stage.failure,
            logLabel: stage.logLabel
        )
        try await renderer.render(url: dryURL, onProgress: stage.onProgress) { dryBuffer in
            try Task.checkCancellation()
            let count = Int(dryBuffer.frameLength)
            guard count > 0,
                  let dry = dryBuffer.floatChannelData?[0],
                  let wet = wetBuffer.floatChannelData?[0] else {
                return
            }
            // The wet stream is the source decoded to 16 kHz, enhanced, and
            // resampled back up — three passes that each round their frame
            // count, so it can end a few frames before the dry does. Mixing
            // what exists and leaving the remainder dry costs an inaudible
            // tail; refusing the block throws away the whole neural pass and
            // silently reverts to DSP-only, which is a far worse trade for a
            // rounding difference.
            //
            // Reading only what remains is what makes that tolerance reachable:
            // `AVAudioFile.read` past the end throws (as a bare
            // `_GenericObjCError`) rather than returning zero frames, so asking
            // for a full block and inspecting `frameLength` afterwards would
            // never see the short read at all.
            let remaining = max(0, Int(wetFile.length - wetFile.framePosition))
            let wanted = min(count, remaining)
            if wanted > 0 {
                try wetFile.read(into: wetBuffer, frameCount: AVAudioFrameCount(wanted))
            } else {
                wetBuffer.frameLength = 0
            }
            let available = min(count, Int(wetBuffer.frameLength))
            shortfall += count - available
            if available > 0 {
                mixed.withUnsafeMutableBufferPointer { mixedPointer in
                    PlaybackMix.mixAligned(
                        dry: UnsafePointer(dry),
                        wet: UnsafePointer(wet),
                        output: mixedPointer.baseAddress!,
                        count: available,
                        wetMix: tuning.wetMix
                    )
                }
                mixed.withUnsafeBufferPointer { mixedPointer in
                    dry.update(from: mixedPointer.baseAddress!, count: available)
                }
            }
            try outputFile?.write(from: dryBuffer)
        }
        outputFile = nil
        if shortfall > 0 {
            let seconds = Double(shortfall) / Self.outputSampleRate
            AppLog.recorder.atNotice.notice("enhance: wet stream ended \(shortfall, privacy: .public) frames (\(seconds, privacy: .public)s) early; that tail is dry")
        }
    }

    private static func makePCMFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try AVAudioFile(forWriting: url, settings: settings)
    }

    private static func write(
        _ samples: [Float],
        to outputFile: AVAudioFile?,
        failure: AppError
    ) throws {
        guard !samples.isEmpty else { return }
        guard let format = OfflineAudioRenderer.monoFormat(sampleRate: 16_000),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData else {
            throw failure
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { samplesPointer in
            channel[0].update(from: samplesPointer.baseAddress!, count: samples.count)
        }
        try outputFile?.write(from: buffer)
    }

    private static func neuralTempURL(label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_enh_\(label)_\(UUID().uuidString).caf")
    }
}

private enum NeuralPassError: Error {
    case inferenceFailed
}

private struct NeuralStage {
    let failure: AppError
    let logLabel: String
    let onProgress: (@Sendable (Double) -> Void)?
}

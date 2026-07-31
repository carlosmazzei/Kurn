//
//  PlaybackEnhancementNeuralPass.swift
//  Kurn
//
//  File-backed neural decode/enhance/resample/mix pass. Every intermediate is
//  Float32 PCM, so the source AAC is decoded exactly once through
//  OfflineAudioRenderer and memory remains bounded by one small audio block.
//

import AudioToolbox
import AVFoundation
import Foundation

extension PlaybackEnhancementRenderer {
    func renderNeuralMix(from sourceURL: URL, failure: AppError) async throws -> URL? {
        guard let streamID = await enhancer.beginStream(),
              let latencyFrames = await enhancer.latencyFrames(
                at: Self.outputSampleRate
              ) else {
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
                failure: failure
            )
            try await Self.enhancePCM(
                decodedURL,
                to: wet16URL,
                enhancer: enhancer,
                streamID: streamID,
                failure: failure
            )
            try await Self.decodePCM(
                wet16URL,
                to: wet24URL,
                sampleRate: Self.outputSampleRate,
                failure: failure
            )
            try await mixPCM(
                dryURL: sourceURL,
                wetURL: wet24URL,
                to: mixedURL,
                latencyFrames: latencyFrames,
                failure: failure
            )
            keepMixed = true
            return mixedURL
        } catch {
            await enhancer.endStream(streamID)
            if error is CancellationError { throw error }
            try ResourceGuard.rethrowIfResourceFailure(error)
            AppLog.recorder.atError.error("enhance: neural pre-pass failed, using DSP only: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func decodePCM(
        _ sourceURL: URL,
        to outputURL: URL,
        sampleRate: Double,
        failure: AppError
    ) async throws {
        guard let format = OfflineAudioRenderer.monoFormat(sampleRate: sampleRate) else {
            throw failure
        }
        var outputFile: AVAudioFile? = try makePCMFile(at: outputURL, sampleRate: sampleRate)
        let renderer = OfflineAudioRenderer(
            outputFormat: format,
            failure: failure,
            logLabel: "enhance.neural.decode"
        )
        try await renderer.render(url: sourceURL) { buffer in
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
        failure: AppError
    ) async throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        var outputFile: AVAudioFile? = try makePCMFile(at: outputURL, sampleRate: 16_000)
        let blockFrames: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: blockFrames
        ) else {
            throw failure
        }

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
            try write(enhanced, to: outputFile, failure: failure)
        }
        outputFile = nil
    }

    private func mixPCM(
        dryURL: URL,
        wetURL: URL,
        to outputURL: URL,
        latencyFrames: Int,
        failure: AppError
    ) async throws {
        guard let format = OfflineAudioRenderer.monoFormat(
            sampleRate: Self.outputSampleRate
        ) else {
            throw failure
        }
        let wetFile = try AVAudioFile(forReading: wetURL)
        wetFile.framePosition = min(AVAudioFramePosition(latencyFrames), wetFile.length)
        guard let wetBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_096
        ) else {
            throw failure
        }
        var outputFile: AVAudioFile? = try Self.makePCMFile(
            at: outputURL,
            sampleRate: Self.outputSampleRate
        )
        var mixed = [Float](repeating: 0, count: 4_096)
        var shortfall = 0
        let renderer = OfflineAudioRenderer(
            outputFormat: format,
            failure: failure,
            logLabel: "enhance.neural.mix"
        )
        try await renderer.render(url: dryURL) { dryBuffer in
            try Task.checkCancellation()
            let count = Int(dryBuffer.frameLength)
            guard count > 0,
                  let dry = dryBuffer.floatChannelData?[0],
                  let wet = wetBuffer.floatChannelData?[0] else {
                return
            }
            try wetFile.read(into: wetBuffer, frameCount: AVAudioFrameCount(count))
            // The wet stream is the source decoded to 16 kHz, enhanced, and
            // resampled back up — three passes that each round their frame
            // count, so it can end a few frames before the dry does. Mixing
            // what exists and leaving the remainder dry costs an inaudible
            // tail; refusing the block throws away the whole neural pass and
            // silently reverts to DSP-only, which is a far worse trade for a
            // rounding difference.
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

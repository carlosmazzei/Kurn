//
//  DiarizationPreprocessor.swift
//  Kurn
//
//  Lighter audio cleanup tailored to speaker diarization. The default
//  `AudioPreprocessor` is tuned for ASR clarity (high makeup gain, 2:1
//  compression, presence EQ boost, AAC encode), which flattens the relative
//  loudness and natural timbre that speaker-embedding models (WeSpeaker inside
//  FluidAudio, and the heuristic pitch/timbre features in `SpeakerDiarizer`)
//  rely on to tell voices apart. This stage keeps the chain minimal:
//
//    DC-removing high-pass (80 Hz) → stationary spectral subtraction
//    (single global per-bin noise floor) → global peak normalization to -3 dBFS
//
//  Output is uncompressed mono 16 kHz Float32 WAV so the diarizer reads it via
//  `AVAudioFile` directly — sidestepping the AAC-decode workaround in
//  `VADAudioLoader` that exists because `AVAudioFile.read`/`AVAudioConverter`
//  silently fail on the app's compressed `.m4a` recordings.
//

import Accelerate
import AVFoundation
import Foundation

actor DiarizationPreprocessor {

    /// Render the diarization-friendly mono 16 kHz Float32 WAV copy to the
    /// temporary directory and return its URL. Caller owns the file and should
    /// `cleanup` it when done.
    func process(url: URL, dereverberate: Bool = false) async throws -> URL {
        try await ResourceGuard.requireTranscriptionHeadroom()
        let started = Date()
        AppLog.transcription.atDebug.debug("diarPreprocess: open \(url.lastPathComponent, privacy: .public)")

        var samples = try await decodeHighPassedMonoSamples(url: url)
        guard samples.count >= Self.fftFrameSize else {
            AppLog.transcription.atError.error("diarPreprocess: too few samples after decode (\(samples.count, privacy: .public))")
            throw AppError.audioError(
                NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
            )
        }
        try await ResourceGuard.requireTranscriptionHeadroom()

        // Dereverberation runs *before* noise reduction on purpose: WPE's linear
        // prediction model assumes the additive noise is small, and spectral
        // subtraction ahead of it would distort the very structure it fits.
        if dereverberate {
            let dereverbStart = Date()
            samples = WPEDereverberator().process(
                samples: samples,
                stft: STFT(frameSize: Self.fftFrameSize, hopSize: Self.fftHopSize)
            )
            AppLog.transcription.atInfo.info("diarPreprocess: dereverb done in \(Date().timeIntervalSince(dereverbStart), privacy: .public)s")
            try await ResourceGuard.requireTranscriptionHeadroom()
        }

        let denoiseStart = Date()
        samples = denoise(samples)
        AppLog.transcription.atDebug.debug("diarPreprocess: denoise done in \(Date().timeIntervalSince(denoiseStart), privacy: .public)s samples=\(samples.count, privacy: .public)")
        try await ResourceGuard.requireTranscriptionHeadroom()

        normalizePeakInPlace(&samples, targetDBFS: Self.targetPeakDBFS)
        try await ResourceGuard.requireTranscriptionHeadroom()

        var outURL: URL?
        let writtenURL = try writeWAV(samples: samples)
        outURL = writtenURL
        defer {
            if let url = outURL { cleanup(url) }
        }

        AppLog.transcription.atInfo.info("diarPreprocess: done in \(Date().timeIntervalSince(started), privacy: .public)s -> \(writtenURL.lastPathComponent, privacy: .public)")
        outURL = nil
        return writtenURL
    }

    /// Remove a diarization-preprocessor output. Only touches files inside the
    /// temporary directory.
    func cleanup(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.path
        guard url.path.hasPrefix(tmp) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Decode + high-pass

    /// Decode `url` through an offline `AVAudioEngine` render with a single
    /// 80 Hz high-pass band, returning mono Float32 samples at 16 kHz. This
    /// reuses the same player-node offline-render path as `AudioPreprocessor`
    /// and `VADAudioLoader` because `AVAudioFile.read` / `AVAudioConverter`
    /// silently fail on the app's compressed AAC `.m4a` files.
    private func decodeHighPassedMonoSamples(url: URL) async throws -> [Float] {
        let failure = AppError.audioError(
            NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
        )
        guard let outputFormat = OfflineAudioRenderer.monoFormat(sampleRate: Self.targetSampleRate) else {
            throw failure
        }

        let renderer = OfflineAudioRenderer(
            outputFormat: outputFormat,
            buildChain: { engine, player, inputFormat in
                let eq = AVAudioUnitEQ(numberOfBands: 1)
                let highPass = eq.bands[0]
                highPass.filterType = .highPass
                highPass.frequency = 80
                highPass.bandwidth = 0.5
                highPass.bypass = false
                eq.globalGain = 0

                engine.attach(eq)
                engine.connect(player, to: eq, format: inputFormat)
                // The main mixer resamples + downmixes to the manual-rendering
                // format (mono @ targetSampleRate), so the EQ → mixer connection
                // keeps the source's own format.
                engine.connect(eq, to: engine.mainMixerNode, format: inputFormat)
            },
            failure: failure,
            logLabel: "diarPreprocess"
        )

        var samples: [Float] = []
        try await renderer.render(url: url) { buffer in
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            samples.append(
                contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
            )
        }
        return samples
    }

    // MARK: - Spectral subtraction

    /// Single-pass stationary noise reduction. The per-bin noise floor is
    /// estimated as the mean magnitude across the quietest 10% of frames (by
    /// RMS), which approximates the spectral profile of a continuous fan / HVAC
    /// background. Each frame's magnitude is reduced by `α · noise[bin]`, with
    /// a floor of `β · noise[bin]` to prevent musical noise from over-subtraction.
    private func denoise(_ samples: [Float]) -> [Float] {
        let frameSize = Self.fftFrameSize
        let hopSize = Self.fftHopSize
        let stft = STFT(frameSize: frameSize, hopSize: hopSize)
        let frameCount = (samples.count - frameSize) / hopSize + 1
        guard frameCount > 0 else { return samples }

        let rms = perFrameRMS(samples: samples, frameSize: frameSize, hopSize: hopSize, frameCount: frameCount)
        let quietCutoff = quietRMSCutoff(rms: rms)
        let noiseFloor = estimateNoiseFloor(
            samples: samples, hopSize: hopSize, rms: rms, cutoff: quietCutoff, stft: stft
        )
        let totalNoise = noiseFloor.reduce(0, +)
        guard totalNoise > 0 else { return samples }

        var output = [Float](repeating: 0, count: samples.count)
        for i in 0..<frameCount {
            let start = i * hopSize
            let cleaned = stft.processFrame(
                samples: samples,
                frameStart: start,
                noiseFloor: noiseFloor,
                alpha: Self.subtractionAlpha,
                beta: Self.subtractionBeta
            )
            cleaned.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    vDSP_vadd(
                        dst.baseAddress!.advanced(by: start), 1,
                        src.baseAddress!, 1,
                        dst.baseAddress!.advanced(by: start), 1,
                        vDSP_Length(frameSize)
                    )
                }
            }
        }
        return output
    }

    private func perFrameRMS(samples: [Float], frameSize: Int, hopSize: Int, frameCount: Int) -> [Float] {
        var rms = [Float](repeating: 0, count: frameCount)
        let inv = Float(frameSize)
        samples.withUnsafeBufferPointer { ptr in
            for i in 0..<frameCount {
                let start = i * hopSize
                var sumSq: Float = 0
                vDSP_svesq(ptr.baseAddress!.advanced(by: start), 1, &sumSq, vDSP_Length(frameSize))
                rms[i] = sqrt(sumSq / inv)
            }
        }
        return rms
    }

    private func quietRMSCutoff(rms: [Float]) -> Float {
        let sorted = rms.sorted()
        let cutoffIndex = max(0, min(sorted.count - 1, sorted.count / 10 - 1))
        return sorted[cutoffIndex]
    }

    private func estimateNoiseFloor(
        samples: [Float],
        hopSize: Int,
        rms: [Float],
        cutoff: Float,
        stft: STFT
    ) -> [Float] {
        var accum = [Float](repeating: 0, count: stft.halfFrame + 1)
        var count: Int = 0
        for i in 0..<rms.count where rms[i] <= cutoff {
            let mags = stft.magnitudes(samples: samples, frameStart: i * hopSize)
            mags.withUnsafeBufferPointer { src in
                accum.withUnsafeMutableBufferPointer { dst in
                    vDSP_vadd(
                        dst.baseAddress!, 1,
                        src.baseAddress!, 1,
                        dst.baseAddress!, 1,
                        vDSP_Length(dst.count)
                    )
                }
            }
            count += 1
        }
        guard count > 0 else { return [] }
        var divisor = Float(count)
        vDSP_vsdiv(accum, 1, &divisor, &accum, 1, vDSP_Length(accum.count))
        return accum
    }

    // MARK: - Peak normalization

    /// Apply a single global gain so the output peaks at `targetDBFS`, with the
    /// gain clamped to `[0.1, 10.0]` so a near-silent clip doesn't blow up.
    /// One gain pass preserves the relative loudness between voices (a cue
    /// embedding models can use), unlike per-frame AGC.
    private func normalizePeakInPlace(_ samples: inout [Float], targetDBFS: Float) {
        var peak: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_maxmgv(ptr.baseAddress!, 1, &peak, vDSP_Length(ptr.count))
        }
        guard peak > 1e-6 else { return }
        let target = pow(10.0, Double(targetDBFS) / 20.0)
        let gainRaw = Float(target / Double(peak))
        var gain = min(max(gainRaw, 0.1), 10.0)
        samples.withUnsafeMutableBufferPointer { ptr in
            vDSP_vsmul(ptr.baseAddress!, 1, &gain, ptr.baseAddress!, 1, vDSP_Length(ptr.count))
        }
    }

    // MARK: - WAV output

    private func writeWAV(samples: [Float]) throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_diar_\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: outURL)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: settings)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.audioError(
                NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
            )
        }
        let chunkFrames = 16_384
        var written = 0
        while written < samples.count {
            let count = min(chunkFrames, samples.count - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                break
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { ptr in
                    channel[0].update(from: ptr.baseAddress!.advanced(by: written), count: count)
                }
            }
            try outFile.write(from: buffer)
            written += count
        }
        return outURL
    }

    // MARK: - Constants

    private static let targetSampleRate: Double = 16_000
    private static let targetPeakDBFS: Float = -3.0
    private static let fftFrameSize: Int = 512
    private static let fftHopSize: Int = 256
    /// Boll 1979 oversubtraction factor. Lowered from 2.0: the speaker-embedding
    /// models this stage feeds are trained on natural, noisy speech and read
    /// voice *timbre*, so the residual distortion heavy oversubtraction leaves
    /// behind costs more discriminative power than the extra noise removal
    /// buys — it flattens voices toward each other, which is exactly the
    /// failure the clustering stage then has to recover from. 1.5 still removes
    /// the stationary bed without scrubbing the formant structure.
    private static let subtractionAlpha: Float = 1.5
    /// Spectral floor as a fraction of the noise estimate; prevents the
    /// musical-noise artifacts that come from clamping bins to zero. Raised
    /// alongside `subtractionAlpha` — a higher floor leaves a little natural
    /// broadband noise in place instead of punching holes in the spectrum for
    /// the embedding model to trip over.
    private static let subtractionBeta: Float = 0.10
}

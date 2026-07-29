//
//  AudioPreprocessor.swift
//  Kurn
//
//  Offline DSP cleanup applied to a recording before transcription.
//  Produces a temporary mono 16 kHz .m4a (the format Speech / Whisper prefer)
//  with a speech-tuned filter chain:
//
//    high-pass (80 Hz, kills rumble/handling) → presence EQ (~2.5 kHz boost for
//    intelligibility) → dynamics processor (measured makeup gain + a gentle
//    downward expander) → peak limiter (clip safety).
//
//  The original full-quality recording is left untouched for playback; only this
//  cleaned copy is fed to the transcription engines.
//
//  **Two passes, not one.** The first renders the EQ'd signal into a
//  `SpeechLevelMeter` and nothing else; the second applies the chain with the
//  makeup gain that measurement implies. The chain used to lift every recording
//  by a fixed +11 dB (a +8 dB makeup on top of the limiter's +3 dB pre-gain),
//  which drives an already-healthy recording into near-constant limiting — and
//  the distortion that leaves behind is the kind of artefact recent work finds
//  *degrading* modern ASR rather than helping it. The extra pass costs roughly
//  double the preprocessing time, which is small next to transcription itself,
//  and it keeps memory flat because the meter reduces each buffer to running
//  sums instead of retaining it.
//

import AudioToolbox
import AVFoundation
import Foundation
import os

actor AudioPreprocessor: AudioPreprocessing {

    /// Sample rate the cleaned copy is rendered at — what Speech and Whisper
    /// prefer, and the rate every downstream engine works in.
    private static let targetSampleRate: Double = 16_000

    /// Render the cleaned, mono 16 kHz copy to the temporary directory and return
    /// its URL. The caller owns the file and should `cleanup` it when done.
    func process(url: URL) async throws -> URL {
        try await ResourceGuard.requireTranscriptionHeadroom()
        let started = Date()
        AppLog.transcription.atDebug.debug("preprocess: open \(url.lastPathComponent, privacy: .public)")

        let failure = AppError.audioError(
            NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
        )

        let level = try await measureLevel(url: url, failure: failure)
        let makeupGainDB = level.makeupGainDB
        AppLog.transcription.atInfo.info("preprocess: level peak=\(level.peakDBFS, privacy: .public)dBFS speech=\(level.speechRMSDBFS, privacy: .public)dBFS -> makeup=\(makeupGainDB, privacy: .public)dB")
        try await ResourceGuard.requireTranscriptionHeadroom()

        let renderStart = Date()
        let outURL = try await renderCleaned(
            url: url,
            makeupGainDB: makeupGainDB,
            failure: failure
        )

        try await ResourceGuard.requireTranscriptionHeadroom()
        AppLog.transcription.atInfo.info("preprocess: done in \(Date().timeIntervalSince(renderStart), privacy: .public)s (total \(Date().timeIntervalSince(started), privacy: .public)s) -> \(outURL.lastPathComponent, privacy: .public)")
        return outURL
    }

    /// Remove a cleaned file. Only touches files inside the temporary directory.
    func cleanup(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.path
        guard url.path.hasPrefix(tmp) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Pass 1: measurement

    /// Render `url` through the EQ alone and measure its level.
    ///
    /// The EQ is included rather than measuring the raw file because the gain is
    /// applied *after* it: low-frequency rumble that the high-pass is about to
    /// remove would otherwise inflate the measured peak and rob the recording of
    /// gain it should have had.
    private func measureLevel(url: URL, failure: AppError) async throws -> SpeechLevel {
        guard let outputFormat = OfflineAudioRenderer.monoFormat(sampleRate: Self.targetSampleRate) else {
            throw failure
        }

        let renderer = OfflineAudioRenderer(
            outputFormat: outputFormat,
            buildChain: { engine, player, inputFormat in
                let eq = Self.makeEQ()
                engine.attach(eq)
                engine.connect(player, to: eq, format: inputFormat)
                engine.connect(eq, to: engine.mainMixerNode, format: inputFormat)
            },
            failure: failure,
            logLabel: "preprocess.measure"
        )

        var meter = SpeechLevelMeter()
        try await renderer.render(url: url) { buffer in
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            meter.append(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        return meter.finish()
    }

    // MARK: - Pass 2: cleanup

    private func renderCleaned(
        url: URL,
        makeupGainDB: Float,
        failure: AppError
    ) async throws -> URL {
        // Render to mono 16 kHz; the engine resamples on the output path.
        guard let outputFormat = OfflineAudioRenderer.monoFormat(sampleRate: Self.targetSampleRate) else {
            throw failure
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_clean_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outURL)
        var success = false
        defer {
            if !success { cleanup(outURL) }
        }

        let outSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: outSettings)

        // Effects are held here so `afterStart` can reach their audio units:
        // `engine.start()` is what initializes them, so parameters can only be
        // set once the renderer has started.
        let dynamics = AVAudioUnitEffect(audioComponentDescription: Self.effect(kAudioUnitSubType_DynamicsProcessor))
        let limiter = AVAudioUnitEffect(audioComponentDescription: Self.effect(kAudioUnitSubType_PeakLimiter))

        let renderer = OfflineAudioRenderer(
            outputFormat: outputFormat,
            buildChain: { engine, player, inputFormat in
                Self.buildChain(
                    engine: engine,
                    player: player,
                    inputFormat: inputFormat,
                    dynamics: dynamics,
                    limiter: limiter
                )
            },
            afterStart: { _ in
                Self.configureDynamics(dynamics.audioUnit, makeupGainDB: makeupGainDB)
                Self.configureLimiter(limiter.audioUnit)
            },
            failure: failure,
            logLabel: "preprocess"
        )

        try await renderer.render(url: url) { buffer in
            try outFile.write(from: buffer)
        }

        success = true
        return outURL
    }

    // MARK: - Unit configuration

    /// High-pass + presence EQ, shared by both passes so the level is measured on
    /// exactly the signal the dynamics stage will see.
    private static func makeEQ() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let highPass = eq.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = 80
        highPass.bypass = false
        let presence = eq.bands[1]
        presence.filterType = .parametric
        presence.frequency = 2500
        presence.bandwidth = 1.0
        presence.gain = 4
        presence.bypass = false
        eq.globalGain = 0
        return eq
    }

    /// Wire high-pass + presence EQ → dynamics → limiter between the player and
    /// the main mixer, all at the source format (the mixer resamples on output).
    private static func buildChain(
        engine: AVAudioEngine,
        player: AVAudioPlayerNode,
        inputFormat: AVAudioFormat,
        dynamics: AVAudioUnitEffect,
        limiter: AVAudioUnitEffect
    ) {
        let eq = makeEQ()

        engine.attach(eq)
        engine.attach(dynamics)
        engine.attach(limiter)

        engine.connect(player, to: eq, format: inputFormat)
        engine.connect(eq, to: dynamics, format: inputFormat)
        engine.connect(dynamics, to: limiter, format: inputFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: inputFormat)
    }

    private static func effect(_ subType: OSType) -> AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// Compress loud peaks and lift the result by the measured makeup gain.
    ///
    /// The expander is kept very soft (1.5:1 at -60 dBFS) so distant or quiet
    /// participants are preserved rather than gated out as background — a gate
    /// chews word tails, and a recogniser cannot recover what it never heard.
    /// The makeup gain is no longer a constant: see `SpeechLevel.makeupGainDB`.
    private static func configureDynamics(_ unit: AudioUnit, makeupGainDB: Float) {
        setParam(unit, kDynamicsProcessorParam_Threshold, -22)
        setParam(unit, kDynamicsProcessorParam_HeadRoom, 5)
        setParam(unit, kDynamicsProcessorParam_ExpansionRatio, 1.5)
        setParam(unit, kDynamicsProcessorParam_ExpansionThreshold, -60)
        setParam(unit, kDynamicsProcessorParam_OverallGain, makeupGainDB)
    }

    /// Safety net only. This used to carry a +3 dB pre-gain, which on top of the
    /// makeup gain kept the limiter in almost constant gain reduction — audible as
    /// harshness, and measurable as distortion the recogniser has to work around.
    /// With the pre-gain at zero the limiter engages only on genuine peaks.
    private static func configureLimiter(_ unit: AudioUnit) {
        setParam(unit, kLimiterParam_PreGain, 0)
    }

    private static func setParam(
        _ unit: AudioUnit,
        _ id: AudioUnitParameterID,
        _ value: AudioUnitParameterValue
    ) {
        _ = AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
    }
}

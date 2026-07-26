//
//  AudioPreprocessor.swift
//  Kurn
//
//  Offline DSP cleanup applied to a recording before transcription.
//  Produces a temporary mono 16 kHz .m4a (the format Speech / Whisper prefer)
//  with a speech-tuned filter chain:
//
//    high-pass (80 Hz, kills rumble/handling) → presence EQ (~2.5 kHz boost for
//    intelligibility) → dynamics processor (AGC makeup + downward-expander gate
//    on residual background) → peak limiter (clip safety).
//
//  The original full-quality recording is left untouched for playback; only this
//  cleaned copy is fed to the transcription engines.
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
                Self.configureDynamics(dynamics.audioUnit)
                Self.configureLimiter(limiter.audioUnit)
            },
            failure: failure,
            logLabel: "preprocess"
        )

        let renderStart = Date()
        try await renderer.render(url: url) { buffer in
            try outFile.write(from: buffer)
        }

        try await ResourceGuard.requireTranscriptionHeadroom()
        success = true
        AppLog.transcription.atInfo.info("preprocess: done in \(Date().timeIntervalSince(renderStart), privacy: .public)s (total \(Date().timeIntervalSince(started), privacy: .public)s) -> \(outURL.lastPathComponent, privacy: .public)")
        return outURL
    }

    /// Remove a cleaned file. Only touches files inside the temporary directory.
    func cleanup(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.path
        guard url.path.hasPrefix(tmp) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Unit configuration

    /// Wire high-pass + presence EQ → dynamics → limiter between the player and
    /// the main mixer, all at the source format (the mixer resamples on output).
    private static func buildChain(
        engine: AVAudioEngine,
        player: AVAudioPlayerNode,
        inputFormat: AVAudioFormat,
        dynamics: AVAudioUnitEffect,
        limiter: AVAudioUnitEffect
    ) {
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

    /// Compress loud peaks, lift the overall level (AGC-style makeup) and apply a
    /// gentle downward expander. Tuned for whole-room capture: the expander is
    /// kept soft (low ratio, low threshold) so distant/quiet participants are
    /// preserved rather than gated out as background. The makeup gain is raised
    /// to help those far voices reach the transcription engines.
    private static func configureDynamics(_ unit: AudioUnit) {
        setParam(unit, kDynamicsProcessorParam_Threshold, -22)
        setParam(unit, kDynamicsProcessorParam_HeadRoom, 5)
        setParam(unit, kDynamicsProcessorParam_ExpansionRatio, 2)
        setParam(unit, kDynamicsProcessorParam_ExpansionThreshold, -60)
        setParam(unit, kDynamicsProcessorParam_OverallGain, 8)
    }

    private static func configureLimiter(_ unit: AudioUnit) {
        setParam(unit, kLimiterParam_PreGain, 3)
    }

    private static func setParam(
        _ unit: AudioUnit,
        _ id: AudioUnitParameterID,
        _ value: AudioUnitParameterValue
    ) {
        _ = AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
    }
}

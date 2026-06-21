//
//  AudioPreprocessor.swift
//  MeetSync
//
//  Offline DSP cleanup applied to a recording before transcription/diarization.
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

actor AudioPreprocessor {

    /// Render the cleaned, mono 16 kHz copy to the temporary directory and return
    /// its URL. The caller owns the file and should `cleanup` it when done.
    func process(url: URL) async throws -> URL {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        let totalInputFrames = inputFile.length
        guard totalInputFrames > 0, inputFormat.sampleRate > 0 else {
            throw AppError.audioError(
                NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
            )
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        // EQ: high-pass + presence boost.
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

        let dynamics = AVAudioUnitEffect(audioComponentDescription: Self.effect(kAudioUnitSubType_DynamicsProcessor))
        let limiter = AVAudioUnitEffect(audioComponentDescription: Self.effect(kAudioUnitSubType_PeakLimiter))

        engine.attach(player)
        engine.attach(eq)
        engine.attach(dynamics)
        engine.attach(limiter)

        engine.connect(player, to: eq, format: inputFormat)
        engine.connect(eq, to: dynamics, format: inputFormat)
        engine.connect(dynamics, to: limiter, format: inputFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: inputFormat)

        // Render to mono 16 kHz; the engine resamples on the output path.
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1
        ) else {
            throw AppError.audioError(
                NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
            )
        }
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: maxFrames)

        try engine.start()
        // Audio units are initialized by `start()`, so set parameters afterwards.
        configureDynamics(dynamics.audioUnit)
        configureLimiter(limiter.audioUnit)
        player.scheduleFile(inputFile, at: nil)
        player.play()

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetsync_clean_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outURL)

        let outSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: outSettings)

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maxFrames
        ) else {
            engine.stop()
            throw AppError.audioError(
                NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
            )
        }

        // Cap on output frames given the resample ratio (safety against runaway).
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let expectedOutFrames = AVAudioFramePosition(Double(totalInputFrames) * ratio)

        renderLoop: while engine.manualRenderingSampleTime < expectedOutFrames {
            let remaining = expectedOutFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(Int64(maxFrames), remaining))
            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            switch status {
            case .success:
                try outFile.write(from: renderBuffer)
            case .insufficientDataFromInputNode:
                // Source exhausted — we're done.
                break renderLoop
            case .cannotDoInCurrentContext, .error:
                break renderLoop
            @unknown default:
                break renderLoop
            }
        }

        player.stop()
        engine.stop()
        return outURL
    }

    /// Remove a cleaned file. Only touches files inside the temporary directory.
    func cleanup(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.path
        guard url.path.hasPrefix(tmp) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Unit configuration

    private static func effect(_ subType: OSType) -> AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// Compress loud peaks, lift the overall level (AGC-style makeup) and gate
    /// residual background below the expansion threshold.
    private func configureDynamics(_ unit: AudioUnit) {
        setParam(unit, kDynamicsProcessorParam_Threshold, -22)
        setParam(unit, kDynamicsProcessorParam_HeadRoom, 5)
        setParam(unit, kDynamicsProcessorParam_ExpansionRatio, 4)
        setParam(unit, kDynamicsProcessorParam_ExpansionThreshold, -45)
        setParam(unit, kDynamicsProcessorParam_OverallGain, 6)
    }

    private func configureLimiter(_ unit: AudioUnit) {
        setParam(unit, kLimiterParam_PreGain, 3)
    }

    private func setParam(
        _ unit: AudioUnit,
        _ id: AudioUnitParameterID,
        _ value: AudioUnitParameterValue
    ) {
        _ = AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
    }
}

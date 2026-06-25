//
//  AudioPreprocessor.swift
//  Kurn
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
import os

actor AudioPreprocessor {

    /// Render the cleaned, mono 16 kHz copy to the temporary directory and return
    /// its URL. The caller owns the file and should `cleanup` it when done.
    func process(url: URL) async throws -> URL {
        let started = Date()
        AppLog.transcription.atDebug.debug("preprocess: open \(url.lastPathComponent, privacy: .public)")
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        let totalInputFrames = inputFile.length
        AppLog.transcription.atDebug.debug("preprocess: input sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) frames=\(totalInputFrames, privacy: .public)")
        guard totalInputFrames > 0, inputFormat.sampleRate > 0 else {
            AppLog.transcription.atError.error("preprocess: invalid input (no frames or zero sample rate)")
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
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.audioError(
                NSLocalizedString("error.audio_cleanup", comment: "Audio cleanup failed")
            )
        }
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: maxFrames)

        try engine.start()
        // Audio units are initialized by `start()`, so set parameters afterwards.
        Self.configureDynamics(dynamics.audioUnit)
        Self.configureLimiter(limiter.audioUnit)
        // Schedule the file for offline rendering. See `scheduleForOfflineRender`
        // for why we must NOT use the async overload here.
        Self.scheduleForOfflineRender(inputFile, on: player)
        player.play()

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_clean_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outURL)

        let outSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
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
        AppLog.transcription.atDebug.debug("preprocess: rendering ~\(expectedOutFrames, privacy: .public) frames @16kHz")

        let renderStart = Date()
        var lastLoggedProgress = 0.0
        renderLoop: while engine.manualRenderingSampleTime < expectedOutFrames {
            let remaining = expectedOutFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(Int64(maxFrames), remaining))
            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            switch status {
            case .success:
                try outFile.write(from: renderBuffer)
            case .insufficientDataFromInputNode:
                // Source exhausted — we're done.
                AppLog.transcription.atDebug.debug("preprocess: input exhausted at \(engine.manualRenderingSampleTime, privacy: .public) frames")
                break renderLoop
            case .cannotDoInCurrentContext, .error:
                AppLog.transcription.atError.error("preprocess: render stopped early (status=\(status.rawValue, privacy: .public)) at \(engine.manualRenderingSampleTime, privacy: .public) frames")
                break renderLoop
            @unknown default:
                break renderLoop
            }
            // Log progress at ~25% increments so a slow/stuck render is visible.
            let progress = Double(engine.manualRenderingSampleTime) / Double(max(1, expectedOutFrames))
            if progress - lastLoggedProgress >= 0.25 {
                lastLoggedProgress = progress
                AppLog.transcription.atDebug.debug("preprocess: render progress \(Int(progress * 100), privacy: .public)%")
            }
        }

        player.stop()
        engine.stop()
        AppLog.transcription.atInfo.info("preprocess: done in \(Date().timeIntervalSince(renderStart), privacy: .public)s (total \(Date().timeIntervalSince(started), privacy: .public)s) -> \(outURL.lastPathComponent, privacy: .public)")
        return outURL
    }

    /// Remove a cleaned file. Only touches files inside the temporary directory.
    func cleanup(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.path
        guard url.path.hasPrefix(tmp) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Schedule a file for offline rendering without awaiting.
    ///
    /// The `async` overload of `scheduleFile` only returns once the file has
    /// finished *playing*, but in offline manual-rendering mode the audio is
    /// consumed solely by the `renderOffline` loop — awaiting it deadlocks (the
    /// loop is never reached, so playback never completes). We deliberately use
    /// the completion-handler overload instead. Keeping this in a synchronous
    /// helper also avoids the compiler's "consider using the asynchronous
    /// alternative" warning that fires when it is called from an `async` context.
    private static func scheduleForOfflineRender(_ file: AVAudioFile, on player: AVAudioPlayerNode) {
        player.scheduleFile(file, at: nil, completionHandler: nil)
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

//
//  AudioRecorderService+Engine.swift
//  Kurn
//

import AVFoundation
import Foundation
import KurnCore
import os

extension AudioRecorderService {
    /// Configure the audio session and start the engine. `nonisolated` + `async`
    /// so the (synchronously blocking) AVFoundation setup runs off the main
    /// actor instead of stalling the UI.
    nonisolated func setUpEngine(
        writingTo url: URL,
        pickup: MicPickup,
        bitRate: Int,
        forceBuiltIn: Bool,
        preferredInputUID: String?
    ) async throws {
        try Task.checkCancellation()
        try await engine.configureSession(
            pickup: pickup,
            forceBuiltIn: forceBuiltIn,
            preferredInputUID: preferredInputUID
        )
        try Task.checkCancellation()
        try await beginEngine(writingTo: url, bitRate: bitRate)
        try Task.checkCancellation()
    }

    // MARK: - Engine

    /// Open the output file and start the engine, installing a tap that writes
    /// captured buffers and tracks the input level. `nonisolated` so it can run
    /// off the main actor from `setUpEngine`.
    private nonisolated func beginEngine(writingTo url: URL, bitRate: Int) async throws {
        engine.disableVoiceProcessing()

        // Right after a session activation that pulled in a Bluetooth route,
        // the accessory may still be mid-handshake switching from A2DP/idle
        // to HFP, so the input format can briefly read as 0/0. Poll briefly
        // before giving up rather than failing on the first read.
        var negotiated = engine.inputFormat
        if negotiated == nil {
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 150_000_000)
                negotiated = engine.inputFormat
                if negotiated != nil { break }
            }
        }
        guard let format = negotiated else {
            AppLog.recorder.atError.error("beginEngine: invalid input format (sampleRate or channelCount is 0)")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
        AppLog.recorder.atDebug.debug("beginEngine: inputFormat sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")

        // Encode at the fixed speech format rather than the mic's native one, so
        // the file size tracks the bit rate alone and a route change can't
        // invalidate the open file.
        guard let storageFormat = Self.storageProcessingFormat else {
            AppLog.recorder.atError.error("beginEngine: could not build the storage format")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
        let file = try engine.openOutputFile(at: url, bitRate: bitRate)

        guard let converter = AudioRecorderEngineSupport.makeConverter(from: format, to: storageFormat) else {
            AppLog.recorder.atError.error("beginEngine: could not build a converter from \(format.sampleRate, privacy: .public)Hz/\(format.channelCount, privacy: .public)ch")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
        sink.open(file, converter: converter, targetFormat: storageFormat, onBuffer: onAudioBuffer)

        // Install the tap from a `nonisolated` context so its block does NOT
        // inherit this type's `@MainActor` isolation. The tap runs on
        // AVAudioEngine's real-time render thread; if the block were main-actor
        // isolated, the Swift runtime would abort (`_dispatch_assert_queue_fail`)
        // on the first buffer because the executor check fails off the main
        // thread.
        engine.installTap(format: format, sink: sink)
        tapInstalled = true
        tapFormat = format

        engine.prepare()
        do {
            try engine.start()
            AppLog.recorder.atDebug.debug("beginEngine: engine.start() succeeded, isRunning=\(self.engine.isRunning, privacy: .public)")
        } catch {
            AppLog.recorder.atError.error("beginEngine: engine.start() failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
    }

    nonisolated func teardownEngine() {
        sink.setPaused(true)
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.removeTap()
            tapInstalled = false
        }
        // Flush and close the output file.
        sink.close()
        // Reset Voice Processing so the next session starts from a clean state.
        engine.disableVoiceProcessing()
    }

    // MARK: - System events

    /// Apply a system event reported by the capture engine. Interruptions and
    /// route loss pause; a stopped engine after a reconfiguration is restarted
    /// in place when possible (see `recoverEngineIfNeeded`).
    func handleCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .interruptionBegan:
            wasRecordingBeforeInterruption = (state == .recording)
            if state == .recording { pause(reason: .audioInterruption) }
        case .interruptionEnded(let shouldResume):
            if wasRecordingBeforeInterruption, shouldResume, state == .paused {
                engine.reactivateSession()
                resume()
                AppLog.recorder.atNotice.notice("handleInterruption: auto-resumed after interruption ended")
            }
            wasRecordingBeforeInterruption = false
        case .inputRouteLost:
            guard state == .recording else { return }
            pause(reason: .routeChanged)
            routeChangeMessage = NSLocalizedString(
                "recorder.route_changed",
                comment: "Recording paused after audio route change"
            )
            AppLog.recorder.atInfo.info("routeChangeMessage: \(self.routeChangeMessage ?? "nil", privacy: .public)")
        case .configurationChanged:
            recoverEngineIfNeeded(reason: "configuration change")
        case .mediaServicesReset:
            recoverEngineIfNeeded(reason: "media services reset")
        }
    }

    /// Restart an engine that stopped mid-recording. When the input format is
    /// unchanged (the common case: the system bounced the engine around a
    /// lock/unlock) the existing tap is still valid and a plain restart resumes
    /// capture seamlessly. When the format DID change, the output file is still
    /// valid — it is written at a fixed format, not the input's — so the tap and
    /// the sink's converter are rebuilt for the new input and recording
    /// continues into the same `.m4a`. Only if that rebuild fails do we fall
    /// back to pausing with a visible banner, so the user resumes deliberately
    /// (resume restarts the engine) instead of silently losing everything after
    /// this moment.
    func recoverEngineIfNeeded(reason: String) {
        guard state == .recording, !engine.isRunning else { return }
        AppLog.recorder.atError.error("engine stopped mid-recording (\(reason, privacy: .public)); attempting restart")

        let current = engine.inputFormat
        let formatUnchanged: Bool
        if let tapFormat, let current {
            formatUnchanged = tapFormat.sampleRate == current.sampleRate && tapFormat.channelCount == current.channelCount
        } else {
            formatUnchanged = false
        }

        if !formatUnchanged {
            AppLog.recorder.atNotice.notice("input format changed to \(current?.sampleRate ?? 0, privacy: .public)Hz/\(current?.channelCount ?? 0, privacy: .public)ch; rebuilding the tap")
            guard let current, rebuildTapForCurrentInput(current) else {
                pause(reason: .engineRecoveryFailed)
                routeChangeMessage = NSLocalizedString(
                    "recorder.engine_stalled",
                    comment: "Recording paused because the system stopped the audio engine"
                )
                AppLog.recorder.atInfo.info("routeChangeMessage: \(self.routeChangeMessage ?? "nil", privacy: .public)")
                return
            }
        }

        engine.reactivateSession()
        engine.prepare()
        do {
            try engine.start()
            AppLog.recorder.atNotice.notice("engine restarted in place after \(reason, privacy: .public)")
            return
        } catch {
            AppLog.recorder.atError.error("engine restart failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        }

        pause(reason: .engineRestartFailed)
        routeChangeMessage = NSLocalizedString(
            "recorder.engine_stalled",
            comment: "Recording paused because the system stopped the audio engine"
        )
        AppLog.recorder.atInfo.info("routeChangeMessage: \(self.routeChangeMessage ?? "nil", privacy: .public)")
    }

    /// Re-point the tap and the sink's converter at a new input format, keeping
    /// the open output file. Returns false if either could not be rebuilt, in
    /// which case the caller pauses rather than capturing nothing.
    private func rebuildTapForCurrentInput(_ format: AVAudioFormat) -> Bool {
        guard let targetFormat = sink.currentTargetFormat,
              let converter = AudioRecorderEngineSupport.makeConverter(from: format, to: targetFormat) else {
            AppLog.recorder.atError.error("rebuildTap: could not build a converter for the new input format")
            return false
        }
        if tapInstalled {
            engine.removeTap()
            tapInstalled = false
        }
        sink.replaceConverter(converter)
        engine.installTap(format: format, sink: sink)
        tapInstalled = true
        tapFormat = format
        return true
    }
}

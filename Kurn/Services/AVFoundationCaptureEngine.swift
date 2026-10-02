//
//  AVFoundationCaptureEngine.swift
//  Kurn
//
//  The production `AudioCaptureEngine`: one `AVAudioEngine` input tap plus the
//  shared `AVAudioSession`, which need a real microphone. The recorder's state
//  machine is tested through `FakeAudioCaptureEngine`; the decisions this
//  engine makes — which notifications become which `AudioCaptureEvent`, the
//  output file's format and its bit-rate fallback, the session's input and
//  category — live in `AudioCaptureEngine.swift` and `CaptureInputSelection`.
//

import AVFoundation
import Foundation

/// Production engine: one `AVAudioEngine` plus the shared `AVAudioSession`.
final class AVFoundationCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var eventHandler: (@Sendable (AudioCaptureEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []

    var onEvent: (@Sendable (AudioCaptureEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    init() {
        registerNotifications()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isRunning: Bool { engine.isRunning }

    var inputFormat: AVAudioFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return format
    }

    func configureSession(pickup: MicPickup, forceBuiltIn: Bool, preferredInputUID: String?) async throws {
        try await CaptureAudioSession.configure(
            pickup: pickup,
            forceBuiltIn: forceBuiltIn,
            preferredInputUID: preferredInputUID
        )
    }

    func reactivateSession() {
        // `setActive` is a synchronous, blocking AVFoundation call; hopping
        // through the nonisolated `AudioSessionActivation` helper keeps that
        // block off whichever thread called `reactivateSession()` (the
        // recorder is `@MainActor`) instead of stalling it.
        Task { try? await AudioSessionActivation.setActive(true) }
    }

    func deactivateSession() {
        Task { await AudioRecorderEngineSupport.deactivateSession() }
    }

    func openOutputFile(at url: URL, bitRate: Int) throws -> any AudioFileWriting {
        try CaptureOutputFile.open(at: url, bitRate: bitRate)
    }

    func installTap(format: AVAudioFormat, sink: any AudioSinkWriting) {
        AudioRecorderEngineSupport.installTap(on: engine.inputNode, format: format, sink: sink)
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Keep the recorder on the standard input unit. VoiceProcessingIO can
    /// block engine startup on some routes/devices, freezing the screen.
    func disableVoiceProcessing() {
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
        // The engine can be stopped out from under a live recording with NO
        // interruption notification: a configuration change (route/sample-rate
        // shuffle, seen around locking and unlocking the device) or a
        // media-services reset. Without these observers the recorder keeps
        // counting elapsed time while no buffers reach the file — silent
        // audio loss with only a frozen level meter as a symptom.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            AppLog.recorder.atInfo.info("handleEngineConfigurationChange: notification received")
            self?.emit(.configurationChanged)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            AppLog.recorder.atInfo.info("handleMediaServicesReset: notification received")
            self?.emit(.mediaServicesReset)
        })
    }

    private func emit(_ event: AudioCaptureEvent) {
        onEvent?(event)
    }

    private func handleInterruption(_ note: Notification) {
        guard let event = AudioCaptureEvent.interruption(userInfo: note.userInfo) else { return }
        if event == .interruptionBegan {
            let interruptionReason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
            AppLog.recorder.atNotice.notice("handleInterruption: began reason=\(AudioRecorderEngineSupport.interruptionReasonDescription(interruptionReason), privacy: .public)")
        } else {
            AppLog.recorder.atNotice.notice("handleInterruption: \(String(describing: event), privacy: .public)")
        }
        emit(event)
    }

    private func handleRouteChange(_ note: Notification) {
        let previousInputs = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
            .inputs.map { $0.portName }.joined(separator: ",") ?? "unknown"
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        AppLog.recorder.atNotice.notice("handleRouteChange: reason=\(String(describing: reason), privacy: .public) previousInputs=\(previousInputs, privacy: .public)")
        // An "old device unavailable" reason means e.g. headphones were pulled.
        guard let event = AudioCaptureEvent.routeChange(userInfo: note.userInfo) else { return }
        emit(event)
    }
}

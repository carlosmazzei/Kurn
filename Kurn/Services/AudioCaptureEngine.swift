//
//  AudioCaptureEngine.swift
//  Kurn
//
//  The hardware surface `AudioRecorderService` records through: the audio
//  session, the input node/tap and the engine's run state, plus the system
//  notifications that interrupt or reconfigure a live capture. The service owns
//  the recording state machine (start / pause / resume / stop, storage, stall
//  watchdog, recovery policy); everything that needs a real microphone or
//  `AVAudioSession` lives behind this protocol so the state machine can be
//  driven by a scripted engine in tests.
//

import AVFoundation
import Foundation

/// System events that reach a live capture from outside the app. The live
/// engine translates `AVAudioSession` / `AVAudioEngine` notifications into
/// these; the recorder decides how each one affects the recording.
enum AudioCaptureEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    /// The input the recording was using disappeared (headphones unplugged,
    /// Bluetooth mic powered off). Other route-change reasons are not
    /// reported: they do not invalidate the capture.
    case inputRouteLost
    /// The engine's graph was reconfigured by the system (lock/unlock, sample
    /// rate shuffle). The engine may have stopped without any interruption.
    case configurationChanged
    case mediaServicesReset
}

protocol AudioCaptureEngine: AnyObject, Sendable {
    /// Invoked off the main actor whenever the system touches the capture.
    var onEvent: (@Sendable (AudioCaptureEvent) -> Void)? { get set }

    var isRunning: Bool { get }
    /// The input node's current output format, or `nil` while the route has
    /// not negotiated one yet (0 Hz / 0 channels, e.g. Bluetooth mid-handshake).
    var inputFormat: AVAudioFormat? { get }

    func configureSession(pickup: MicPickup, forceBuiltIn: Bool, preferredInputUID: String?) async throws
    /// Best-effort `setActive(true)` used before restarting a stopped engine.
    func reactivateSession()
    func deactivateSession()

    /// Open the encoded output file the sink writes to.
    func openOutputFile(at url: URL, bitRate: Int) throws -> any AudioFileWriting
    func installTap(format: AVAudioFormat, sink: any AudioSinkWriting)
    func removeTap()
    func disableVoiceProcessing()

    func prepare()
    func start() throws
    func stop()
}

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
        try await AudioRecorderEngineSupport.configureSession(
            pickup: pickup,
            forceBuiltIn: forceBuiltIn,
            preferredInputUID: preferredInputUID
        )
    }

    func reactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func deactivateSession() {
        AudioRecorderEngineSupport.deactivateSession()
    }

    func openOutputFile(at url: URL, bitRate: Int) throws -> any AudioFileWriting {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: AudioRecorderService.storageSampleRate,
            AVNumberOfChannelsKey: Int(AudioRecorderService.storageChannelCount),
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        // Kept from when the encoder saw the mic's native rate: some routes
        // (e.g. Bluetooth HFP hearing aids negotiating a narrowband link) had a
        // sample rate whose AAC encoder rejected an explicit bit rate this high,
        // throwing out of AVAudioFile's init. The fixed 24kHz mono format
        // should never trip that, but failing a whole recording over an encoder
        // property is not worth the saved lines.
        do {
            return try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            AppLog.recorder.atError.error(
                "beginEngine: AVAudioFile open failed with bitRate=\(bitRate, privacy: .public); retrying without explicit bit rate code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            var fallbackSettings = settings
            fallbackSettings.removeValue(forKey: AVEncoderBitRateKey)
            do {
                return try AVAudioFile(forWriting: url, settings: fallbackSettings)
            } catch {
                AppLog.recorder.atError.error("beginEngine: AVAudioFile open failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
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
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            let interruptionReason = (info[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
            AppLog.recorder.atNotice.notice("handleInterruption: began reason=\(AudioRecorderEngineSupport.interruptionReasonDescription(interruptionReason), privacy: .public)")
            emit(.interruptionBegan)
        case .ended:
            let shouldResume: Bool
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            } else {
                shouldResume = false
            }
            AppLog.recorder.atNotice.notice("handleInterruption: ended shouldResume=\(shouldResume, privacy: .public)")
            emit(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        let previousInputs = (info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
            .inputs.map { $0.portName }.joined(separator: ",") ?? "unknown"
        AppLog.recorder.atNotice.notice("handleRouteChange: reason=\(String(describing: reason), privacy: .public) previousInputs=\(previousInputs, privacy: .public)")

        // An "old device unavailable" reason means e.g. headphones were pulled.
        guard reason == .oldDeviceUnavailable else { return }
        emit(.inputRouteLost)
    }
}

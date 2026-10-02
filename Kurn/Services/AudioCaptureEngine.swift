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

extension AudioCaptureEvent {
    /// The event an `AVAudioSession.interruptionNotification` carries, or
    /// `nil` for a notification without a recognisable type. An `ended`
    /// without options never asks to resume.
    static func interruption(userInfo: [AnyHashable: Any]?) -> AudioCaptureEvent? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let options = (userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    /// The event an `AVAudioSession.routeChangeNotification` carries: only a
    /// lost input (headphones pulled, Bluetooth mic off) matters to a live
    /// capture; every other reason is `nil`.
    static func routeChange(userInfo: [AnyHashable: Any]?) -> AudioCaptureEvent? {
        guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return nil }
        return .inputRouteLost
    }
}

/// The encoded file a recording is written to: mono AAC at the storage rate.
enum CaptureOutputFile {
    static func settings(bitRate: Int?) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: AudioRecorderService.storageSampleRate,
            AVNumberOfChannelsKey: Int(AudioRecorderService.storageChannelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        if let bitRate { settings[AVEncoderBitRateKey] = bitRate }
        return settings
    }

    /// Kept from when the encoder saw the mic's native rate: some routes
    /// (e.g. Bluetooth HFP hearing aids negotiating a narrowband link) had a
    /// sample rate whose AAC encoder rejected an explicit bit rate this high,
    /// throwing out of AVAudioFile's init. The fixed 24kHz mono format
    /// should never trip that, but failing a whole recording over an encoder
    /// property is not worth the saved lines — so a rejected bit rate is
    /// retried once with the encoder's own choice.
    static func open(
        at url: URL,
        bitRate: Int,
        make: (URL, [String: Any]) throws -> any AudioFileWriting = { try AVAudioFile(forWriting: $0, settings: $1) }
    ) throws -> any AudioFileWriting {
        do {
            return try make(url, settings(bitRate: bitRate))
        } catch {
            AppLog.recorder.atError.error(
                "beginEngine: AVAudioFile open failed with bitRate=\(bitRate, privacy: .public); retrying without explicit bit rate code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            do {
                return try make(url, settings(bitRate: nil))
            } catch {
                AppLog.recorder.atError.error("beginEngine: AVAudioFile open failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }
}

//
//  AudioRecorderService.swift
//  MeetSync
//
//  AVAudioRecorder wrapper providing the core recording loop: start / pause /
//  resume / stop, real-time level metering, and resilient handling of audio
//  session interruptions and route changes. Recording is fully offline — the
//  .m4a is written directly to Documents and survives connectivity loss.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioRecorderService: NSObject {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    private(set) var state: State = .idle
    /// Normalized 0...1 microphone level driven from the metering timer.
    private(set) var level: Float = 0
    /// Elapsed recording time (excludes paused spans).
    private(set) var elapsed: TimeInterval = 0
    /// Set when a route change (e.g. headphones unplugged) auto-paused us.
    private(set) var routeChangeMessage: String?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentFileName: String?
    /// Accumulated time across pause cycles plus the active span.
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    @ObservationIgnored var onStateChanged: ((State, TimeInterval) -> Void)?

    /// Whether the user was recording when an interruption began, so we can
    /// decide whether to auto-resume when it ends.
    private var wasRecordingBeforeInterruption = false

    override init() {
        super.init()
        registerNotifications()
    }

    // MARK: - Permissions

    /// Request microphone permission. Returns true if granted.
    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording lifecycle

    /// Begin recording into a new file for the given meeting. Throws `AppError`
    /// on permission or session/file failures.
    func start(meetingID: UUID) throws {
        guard state == .idle else { return }

        try configureSession()

        let fileName = AudioFileStore.fileName(meetingID: meetingID)
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw AppError.audioError(
                    NSLocalizedString("error.recorder_start", comment: "Recorder failed to start")
                )
            }
            self.recorder = recorder
            self.currentFileName = fileName
            self.accumulated = 0
            self.segmentStart = Date()
            self.elapsed = 0
            self.routeChangeMessage = nil
            self.state = .recording
            notifyStateChanged()
            startMetering()
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.audioError(error.localizedDescription)
        }
    }

    func pause() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        accumulateElapsed()
        stopMetering()
        level = 0
        state = .paused
        notifyStateChanged()
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        guard recorder.record() else { return }
        segmentStart = Date()
        routeChangeMessage = nil
        state = .recording
        notifyStateChanged()
        startMetering()
    }

    /// Stop and finalize. Returns the saved file name and total duration, or nil
    /// if nothing was recorded. The session is deactivated afterwards.
    @discardableResult
    func stop() -> (fileName: String, duration: TimeInterval)? {
        guard state != .idle, let recorder, let fileName = currentFileName else {
            return nil
        }
        accumulateElapsed()
        recorder.stop()
        stopMetering()

        let duration = accumulated
        self.recorder = nil
        self.currentFileName = nil
        self.state = .idle
        self.level = 0
        self.elapsed = 0
        self.accumulated = 0
        self.segmentStart = nil
        notifyStateChanged()

        deactivateSession()
        return (fileName, duration)
    }

    /// Abort the current recording and delete its partial file.
    func cancel() {
        guard let recorder, let fileName = currentFileName else { return }
        recorder.stop()
        stopMetering()
        AudioFileStore.delete(fileName: fileName)
        self.recorder = nil
        self.currentFileName = nil
        self.state = .idle
        self.level = 0
        self.elapsed = 0
        self.accumulated = 0
        self.segmentStart = nil
        notifyStateChanged()
        deactivateSession()
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            throw AppError.audioError(error.localizedDescription)
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    // MARK: - Metering / timing

    private func accumulateElapsed() {
        if let start = segmentStart {
            accumulated += Date().timeIntervalSince(start)
            segmentStart = nil
        }
        elapsed = accumulated
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func tick() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        // Map dBFS (-160...0) to a perceptual 0...1 with a noise floor.
        let power = recorder.averagePower(forChannel: 0)
        let floor: Float = -50
        let clamped = max(floor, power)
        level = (clamped - floor) / (-floor)
        if let start = segmentStart {
            elapsed = accumulated + Date().timeIntervalSince(start)
        }
    }

    private func notifyStateChanged() {
        onStateChanged?(state, elapsed)
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            Task { @MainActor in
                self.wasRecordingBeforeInterruption = (self.state == .recording)
                if self.state == .recording { self.pause() }
            }
        case .ended:
            let shouldResume: Bool
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            } else {
                shouldResume = false
            }
            Task { @MainActor in
                if self.wasRecordingBeforeInterruption,
                   shouldResume,
                   self.state == .paused {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.resume()
                }
                self.wasRecordingBeforeInterruption = false
            }
        @unknown default:
            break
        }
    }

    @objc private nonisolated func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        // An "old device unavailable" reason means e.g. headphones were pulled.
        guard reason == .oldDeviceUnavailable else { return }

        Task { @MainActor in
            if self.state == .recording {
                self.pause()
                self.routeChangeMessage = NSLocalizedString(
                    "recorder.route_changed",
                    comment: "Recording paused after audio route change"
                )
            }
        }
    }
}

extension AudioRecorderService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        Task { @MainActor in
            self.routeChangeMessage = error?.localizedDescription
        }
    }
}

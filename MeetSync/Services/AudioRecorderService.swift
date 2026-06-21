//
//  AudioRecorderService.swift
//  MeetSync
//
//  AVAudioEngine-based recorder providing the core recording loop: start / pause
//  / resume / stop, real-time level metering, and resilient handling of audio
//  session interruptions and route changes.
//
//  Unlike a plain AVAudioRecorder, the engine writes input buffers directly to
//  disk while publishing real-time levels to the UI. We also steer the built-in
//  microphone toward a directional (cardioid) polar pattern when no external mic
//  is attached, favouring the speaker in front. Recording stays fully offline —
//  buffers are written straight to a Documents .m4a and survive connectivity loss.
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

    private let engine = AVAudioEngine()
    /// Thread-safe sink that owns the output file and the latest level. The input
    /// tap runs on a render thread, so it talks to the sink rather than to this
    /// main-actor object directly.
    private let sink = RecordingSink()
    private var tapInstalled = false

    private var meterTimer: Timer?
    private var currentFileName: String?
    /// Accumulated time across pause cycles plus the active span.
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    @ObservationIgnored var onStateChanged: ((State, TimeInterval) -> Void)?
    /// Fired on every metering tick (~50ms) while recording, for low-latency
    /// mirroring (e.g. to the Watch app). Not used for UI state transitions.
    @ObservationIgnored var onLevelChanged: ((Float) -> Void)?

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

        do {
            try beginEngine(writingTo: url)
            self.currentFileName = fileName
            self.accumulated = 0
            self.segmentStart = Date()
            self.elapsed = 0
            self.routeChangeMessage = nil
            self.state = .recording
            notifyStateChanged()
            startMetering()
        } catch let error as AppError {
            teardownEngine()
            deactivateSession()
            throw error
        } catch {
            teardownEngine()
            deactivateSession()
            throw AppError.audioError(error.localizedDescription)
        }
    }

    func pause() {
        guard state == .recording else { return }
        sink.setPaused(true)
        accumulateElapsed()
        stopMetering()
        level = 0
        state = .paused
        notifyStateChanged()
    }

    func resume() {
        guard state == .paused else { return }
        // An interruption may have stopped the engine while we were paused.
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        sink.setPaused(false)
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
        guard state != .idle, let fileName = currentFileName else {
            return nil
        }
        accumulateElapsed()
        stopMetering()
        teardownEngine()

        let duration = accumulated
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
        guard let fileName = currentFileName else { return }
        stopMetering()
        teardownEngine()
        AudioFileStore.delete(fileName: fileName)
        self.currentFileName = nil
        self.state = .idle
        self.level = 0
        self.elapsed = 0
        self.accumulated = 0
        self.segmentStart = nil
        notifyStateChanged()
        deactivateSession()
    }

    // MARK: - Engine

    /// Open the output file and start the engine, installing a tap that writes
    /// captured buffers and tracks the input level.
    private func beginEngine(writingTo url: URL) throws {
        let input = engine.inputNode
        // Keep the recorder on the standard input unit. VoiceProcessingIO can
        // block engine startup on some routes/devices, freezing this screen.
        try? input.setVoiceProcessingEnabled(false)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }

        // Derive AAC .m4a settings from the live input format so the encoder
        // matches the buffers the tap delivers.
        var settings = format.settings
        settings[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC)
        settings[AVEncoderBitRateKey] = 64_000
        settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue

        let file = try AVAudioFile(forWriting: url, settings: settings)
        sink.open(file)

        let bufferSink = sink
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            bufferSink.write(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
    }

    private func teardownEngine() {
        sink.setPaused(true)
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Flush and close the output file.
        sink.close()
        // Reset Voice Processing so the next session starts from a clean state.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
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
            configureMicrophone(session)
        } catch {
            throw AppError.audioError(error.localizedDescription)
        }
    }

    /// Steer the built-in mic toward a directional pickup. Skipped entirely when
    /// an external mic (Bluetooth / wired headset) is available, so we never
    /// override the user's preferred input.
    private func configureMicrophone(_ session: AVAudioSession) {
        guard let inputs = session.availableInputs else { return }
        let hasExternal = inputs.contains { $0.portType != .builtInMic }
        guard !hasExternal,
              let builtIn = inputs.first(where: { $0.portType == .builtInMic }) else { return }

        try? session.setPreferredInput(builtIn)

        guard let sources = builtIn.dataSources, !sources.isEmpty else { return }
        // Prefer cardioid (most directional), then subcardioid.
        let directional = sources.first { ds in
            ds.supportedPolarPatterns?.contains(.cardioid) == true
        } ?? sources.first { ds in
            ds.supportedPolarPatterns?.contains(.subcardioid) == true
        }
        guard let source = directional else { return }
        if source.supportedPolarPatterns?.contains(.cardioid) == true {
            try? source.setPreferredPolarPattern(.cardioid)
        } else {
            try? source.setPreferredPolarPattern(.subcardioid)
        }
        try? builtIn.setPreferredDataSource(source)
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
        guard state == .recording else { return }
        // Level is computed off the render thread by the sink; just publish it.
        level = sink.currentLevel
        onLevelChanged?(level)
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

/// Thread-safe owner of the recording file and the latest input level. The audio
/// tap runs on a real-time render thread; routing all file/level access through
/// this lock-guarded box keeps it off the main actor and free of data races.
private final class RecordingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var paused = true
    private var level: Float = 0

    func open(_ file: AVAudioFile) {
        lock.lock(); defer { lock.unlock() }
        self.file = file
        paused = false
        level = 0
    }

    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        if value { level = 0 }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil
        paused = true
        level = 0
    }

    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !paused, let file else { return }
        try? file.write(from: buffer)
        level = Self.level(of: buffer)
    }

    /// Map a buffer's RMS energy to a perceptual 0...1 with a −50 dBFS floor,
    /// matching the metering curve the UI was tuned against.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        let samples = channels[0]
        for i in 0..<frames {
            let sample = samples[i]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let floor: Float = -50
        let clamped = max(floor, db)
        return (clamped - floor) / (-floor)
    }
}

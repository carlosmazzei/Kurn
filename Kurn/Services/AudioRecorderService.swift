//
//  AudioRecorderService.swift
//  Kurn
//
//  AVAudioEngine-based recorder providing the core recording loop: start / pause
//  / resume / stop, real-time level metering, and resilient handling of audio
//  session interruptions and route changes.
//
//  Unlike a plain AVAudioRecorder, the engine writes input buffers directly to
//  disk while publishing real-time levels to the UI. We also steer the built-in
//  microphone toward an omnidirectional polar pattern when no external mic is
//  attached, so the whole room is captured rather than just the person in front.
//  Recording stays fully offline — buffers are written straight to a Documents
//  .m4a and survive connectivity loss.
//

import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class AudioRecorderService: NSObject {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    private(set) var state: State = .idle
    /// Preferred built-in mic pickup pattern. Set before `start`. Defaults to
    /// whole-room (omnidirectional) capture.
    var micPickup: MicPickup = .wholeRoom
    /// AAC encoder bit rate (bits/sec) for the output file. Set before `start`.
    var audioBitRate: Int = 64_000
    /// Normalized 0...1 microphone level driven from the metering timer.
    private(set) var level: Float = 0
    /// Elapsed recording time (excludes paused spans).
    private(set) var elapsed: TimeInterval = 0
    /// Set when a route change (e.g. headphones unplugged) auto-paused us.
    private(set) var routeChangeMessage: String?

    // The engine, sink and tap flag are touched by the off-main setup/teardown
    // path (see `setUpEngine`), so they are kept out of main-actor isolation and
    // out of observation. Access is serialized by the `state`/`isStarting` guards.
    @ObservationIgnored private nonisolated(unsafe) let engine = AVAudioEngine()
    /// Thread-safe sink that owns the output file and the latest level. The input
    /// tap runs on a render thread, so it talks to the sink rather than to this
    /// main-actor object directly.
    @ObservationIgnored private nonisolated let sink = RecordingSink()
    @ObservationIgnored private nonisolated(unsafe) var tapInstalled = false
    /// True while `start` is asynchronously spinning up the engine, to block
    /// re-entrant start attempts during that window.
    @ObservationIgnored private var isStarting = false

    private var meterTimer: Timer?
    /// Counts metering ticks so we can log progress without flooding the console.
    private var tickCount = 0
    private var currentFileName: String?
    /// Accumulated time across pause cycles plus the active span.
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    @ObservationIgnored var onStateChanged: ((State, TimeInterval) -> Void)?
    /// Fired on every metering tick (~50ms) while recording, for low-latency
    /// mirroring (e.g. to the Watch app). Not used for UI state transitions.
    @ObservationIgnored var onLevelChanged: ((Float) -> Void)?
    /// Fired with every raw captured buffer (e.g. for live transcription
    /// preview). Called on the audio render thread, like the tap itself —
    /// `nonisolated(unsafe)` so setting it doesn't require the main actor.
    @ObservationIgnored nonisolated(unsafe) var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

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
        let current = AVAudioApplication.shared.recordPermission
        AppLog.recorder.debug("requestMicrophonePermission: current=\(String(describing: current), privacy: .public)")
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        AppLog.recorder.info("requestMicrophonePermission: granted=\(granted, privacy: .public)")
        return granted
    }

    // MARK: - Recording lifecycle

    /// Begin recording into a new file for the given meeting. Throws `AppError`
    /// on permission or session/file failures.
    func start(meetingID: UUID) async throws {
        AppLog.recorder.notice("start: requested for meeting=\(meetingID, privacy: .public) currentState=\(String(describing: self.state), privacy: .public)")
        guard state == .idle, !isStarting else {
            AppLog.recorder.debug("start: ignored (not idle or already starting)")
            return
        }
        isStarting = true
        defer { isStarting = false }

        let pickup = micPickup
        let bitRate = audioBitRate
        let fileName = AudioFileStore.fileName(meetingID: meetingID)
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        AppLog.recorder.debug("start: writing to \(fileName, privacy: .public)")

        do {
            // Heavy AVAudioSession + AVAudioEngine setup runs OFF the main actor
            // (see `setUpEngine`) so the UI — e.g. the recorder sheet animating
            // in — stays responsive while the engine spins up.
            try await setUpEngine(writingTo: url, pickup: pickup, bitRate: bitRate)
        } catch let error as AppError {
            AppLog.recorder.error("start: setup threw AppError: \(error.errorDescription ?? "nil", privacy: .public)")
            teardownEngine()
            deactivateSession()
            throw error
        } catch {
            AppLog.recorder.error("start: setup threw: \(error.localizedDescription, privacy: .public)")
            teardownEngine()
            deactivateSession()
            throw AppError.audioError(error.localizedDescription)
        }

        // Back on the main actor: publish state and start the metering timer.
        self.currentFileName = fileName
        self.accumulated = 0
        self.segmentStart = Date()
        self.elapsed = 0
        self.routeChangeMessage = nil
        self.state = .recording
        notifyStateChanged()
        startMetering()
        AppLog.recorder.notice("start: engine running, state=recording")
    }

    /// Configure the audio session and start the engine. `nonisolated` + `async`
    /// so the (synchronously blocking) AVFoundation setup runs off the main
    /// actor instead of stalling the UI.
    private nonisolated func setUpEngine(writingTo url: URL, pickup: MicPickup, bitRate: Int) async throws {
        try configureSession(pickup: pickup)
        try beginEngine(writingTo: url, bitRate: bitRate)
    }

    func pause() {
        AppLog.recorder.info("pause: called state=\(String(describing: self.state), privacy: .public)")
        guard state == .recording else { return }
        sink.setPaused(true)
        accumulateElapsed()
        stopMetering()
        level = 0
        state = .paused
        notifyStateChanged()
    }

    func resume() {
        AppLog.recorder.info("resume: called state=\(String(describing: self.state), privacy: .public)")
        guard state == .paused else { return }
        // An interruption may have stopped the engine while we were paused.
        if !engine.isRunning {
            do { try engine.start() } catch {
                AppLog.recorder.error("resume: engine.start() failed: \(error.localizedDescription, privacy: .public)")
                return
            }
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
        AppLog.recorder.notice("stop: called state=\(String(describing: self.state), privacy: .public) file=\(self.currentFileName ?? "nil", privacy: .public)")
        guard state != .idle, let fileName = currentFileName else {
            AppLog.recorder.debug("stop: nothing to stop (idle or no file)")
            return nil
        }
        accumulateElapsed()
        stopMetering()
        teardownEngine()

        let duration = accumulated
        AppLog.recorder.notice("stop: finalized file=\(fileName, privacy: .public) duration=\(duration, privacy: .public)s")
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
    /// captured buffers and tracks the input level. `nonisolated` so it can run
    /// off the main actor from `setUpEngine`.
    private nonisolated func beginEngine(writingTo url: URL, bitRate: Int) throws {
        let input = engine.inputNode
        // Keep the recorder on the standard input unit. VoiceProcessingIO can
        // block engine startup on some routes/devices, freezing this screen.
        try? input.setVoiceProcessingEnabled(false)

        let format = input.outputFormat(forBus: 0)
        AppLog.recorder.debug("beginEngine: inputFormat sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            AppLog.recorder.error("beginEngine: invalid input format (sampleRate or channelCount is 0)")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }

        // Derive AAC .m4a settings from the live input format so the encoder
        // matches the buffers the tap delivers.
        var settings = format.settings
        settings[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC)
        settings[AVEncoderBitRateKey] = bitRate
        settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            AppLog.recorder.error("beginEngine: AVAudioFile open failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        sink.open(file, onBuffer: onAudioBuffer)

        // Install the tap from a `nonisolated` context so its block does NOT
        // inherit this type's `@MainActor` isolation. The tap runs on
        // AVAudioEngine's real-time render thread; if the block were main-actor
        // isolated, the Swift runtime would abort (`_dispatch_assert_queue_fail`)
        // on the first buffer because the executor check fails off the main
        // thread.
        Self.installTap(on: input, format: format, sink: sink)
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            AppLog.recorder.debug("beginEngine: engine.start() succeeded, isRunning=\(self.engine.isRunning, privacy: .public)")
        } catch {
            AppLog.recorder.error("beginEngine: engine.start() failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
    }

    /// Install the input tap. Declared `nonisolated` so the block it creates is
    /// NOT inferred as `@MainActor`-isolated: AVAudioEngine invokes it on its
    /// real-time render thread, where a main-actor isolation check would abort.
    /// The block only touches `sink`, which is thread-safe (`@unchecked Sendable`).
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        sink: RecordingSink
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.write(buffer)
        }
    }

    private nonisolated func teardownEngine() {
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

    private nonisolated func configureSession(pickup: MicPickup) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
            configureMicrophone(session, pickup: pickup)
            AppLog.recorder.debug("configureSession: active route=\(session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","), privacy: .public) sampleRate=\(session.sampleRate, privacy: .public)")
        } catch {
            AppLog.recorder.error("configureSession: failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.audioError(error.localizedDescription)
        }
    }

    /// Configure the built-in mic's polar pattern according to `micPickup`:
    /// whole-room favours an omnidirectional pickup (every participant), while
    /// focus-speaker favours cardioid (the person in front). Both fall back to
    /// subcardioid, then the hardware default. Skipped entirely when an external
    /// mic (Bluetooth / wired headset) is available, so we never override the
    /// user's preferred input.
    private nonisolated func configureMicrophone(_ session: AVAudioSession, pickup: MicPickup) {
        guard let inputs = session.availableInputs else { return }
        let hasExternal = inputs.contains { $0.portType != .builtInMic }
        guard !hasExternal,
              let builtIn = inputs.first(where: { $0.portType == .builtInMic }) else { return }

        try? session.setPreferredInput(builtIn)

        guard let sources = builtIn.dataSources, !sources.isEmpty else { return }

        // Try patterns in priority order for the chosen pickup mode; apply the
        // first one the hardware actually supports.
        let preferredPatterns: [AVAudioSession.PolarPattern] = pickup == .wholeRoom
            ? [.omnidirectional, .subcardioid]
            : [.cardioid, .subcardioid]

        for pattern in preferredPatterns {
            guard let source = sources.first(where: {
                $0.supportedPolarPatterns?.contains(pattern) == true
            }) else { continue }
            try? source.setPreferredPolarPattern(pattern)
            try? builtIn.setPreferredDataSource(source)
            AppLog.recorder.debug("configureMicrophone: pickup=\(pickup.rawValue, privacy: .public) pattern=\(pattern.rawValue, privacy: .public) source=\(source.dataSourceName, privacy: .public)")
            return
        }
        AppLog.recorder.debug("configureMicrophone: pickup=\(pickup.rawValue, privacy: .public) hardware default pattern (no preferred pattern available)")
    }

    private nonisolated func deactivateSession() {
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
        AppLog.recorder.debug("startMetering: scheduling timer")
        tickCount = 0
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, so we are already on the main
            // actor's executor. Call `tick()` directly via `assumeIsolated`
            // instead of spawning a Task every 50 ms — that 20 Hz task churn
            // caused periodic scheduling hitches in the UI.
            MainActor.assumeIsolated { self?.tick() }
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
            let newElapsed = accumulated + Date().timeIntervalSince(start)
            // The on-screen counter only shows whole seconds, so publish `elapsed`
            // (an observed property) just once per second instead of 20×/second —
            // this avoids invalidating the recorder view on every metering tick.
            if Int(newElapsed) != Int(elapsed) {
                elapsed = newElapsed
            }
        }
        // Log roughly once per second so we can confirm the timer keeps firing.
        tickCount += 1
        if tickCount == 1 || tickCount % 20 == 0 {
            AppLog.recorder.debug("tick #\(self.tickCount, privacy: .public): elapsed=\(self.elapsed, privacy: .public) level=\(self.level, privacy: .public)")
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
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func open(_ file: AVAudioFile, onBuffer: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.file = file
        self.onBuffer = onBuffer
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
        onBuffer = nil
        paused = true
        level = 0
    }

    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !paused, let file else { lock.unlock(); return }
        try? file.write(from: buffer)
        level = Self.level(of: buffer)
        let callback = onBuffer
        lock.unlock()
        callback?(buffer)
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

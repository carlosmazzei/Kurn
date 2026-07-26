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
//  The stored format is deliberately NOT the microphone's native format: every
//  buffer is resampled to `storageSampleRate` mono before it reaches the file
//  (see `RecordingSink`). See that constant for why, and note the knock-on
//  benefit in `recoverEngineIfNeeded` — with the file format decoupled from the
//  input, a mid-recording route change no longer invalidates the open file.
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

    /// Sample rate every recording is stored at, regardless of what the
    /// microphone route negotiates (typically 48kHz built-in, 16kHz Bluetooth
    /// HFP). Speech occupies roughly 80Hz–8kHz, so 24kHz mono — a 12kHz band —
    /// is transparent for voice even at the 2x playback `AudioPlayerService`
    /// offers, while every machine consumer of the audio resamples to 16kHz
    /// anyway (`AudioPreprocessor`, `DiarizationPreprocessor`, `VADAudioLoader`,
    /// `WhisperCppTranscriber`, and the ASR frameworks internally). Storing the
    /// mic's native rate therefore spent bits on a band nothing reads.
    /// `nonisolated` because this type is `@MainActor`, which its statics would
    /// otherwise inherit — and the engine setup (`beginEngine`) and
    /// `RecordingCompactor` both read these from outside the main actor.
    nonisolated static let storageSampleRate: Double = 24_000
    /// Recordings are always mono: diarization and ASR both downmix, and the
    /// second channel of a stereo external mic doubles the file for nothing.
    nonisolated static let storageChannelCount: AVAudioChannelCount = 1

    /// The format buffers are converted to before being encoded. Non-nil for
    /// every sample rate/channel pair we pass, but `AVAudioFormat`'s initializer
    /// is failable, so callers treat `nil` as a setup failure.
    nonisolated static var storageProcessingFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: storageSampleRate,
            channels: storageChannelCount,
            interleaved: false
        )
    }

    private(set) var state: State = .idle
    /// Preferred built-in mic pickup pattern. Set before `start`. Defaults to
    /// whole-room (omnidirectional) capture.
    var micPickup: MicPickup = .wholeRoom
    /// AAC encoder bit rate (bits/sec) for the output file. Set before `start`.
    var audioBitRate: Int = AudioQuality.standard.bitRate
    /// When true, always select the iPhone's built-in microphone even if an
    /// external (e.g. Bluetooth) input is connected, and skip offering a
    /// choice. Set before `start`. Mirrors `AppSettings.alwaysUseBuiltInMic`.
    var forceBuiltInMic = false
    /// Explicit input chosen by the caller (e.g. via a microphone picker) for
    /// this recording, identified by `AVAudioSessionPortDescription.uid`. Set
    /// before `start`. `nil` defers to `forceBuiltInMic`/the system route.
    var preferredInputUID: String?
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
    /// Input format the tap was created with, so the engine-stall recovery can
    /// tell a plain restart (same format) from one that needs the tap and the
    /// sink's converter rebuilt for a new input format.
    @ObservationIgnored private nonisolated(unsafe) var tapFormat: AVAudioFormat?
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
        AppLog.recorder.atDebug.debug("requestMicrophonePermission: current=\(String(describing: current), privacy: .public)")
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        AppLog.recorder.atInfo.info("requestMicrophonePermission: granted=\(granted, privacy: .public)")
        return granted
    }

    // MARK: - Recording lifecycle

    /// Begin recording into a new file for the given meeting. Throws `AppError`
    /// on permission or session/file failures.
    func start(meetingID: UUID) async throws {
        AppLog.recorder.atNotice.notice("start: requested for meeting=\(meetingID, privacy: .public) currentState=\(String(describing: self.state), privacy: .public)")
        guard state == .idle, !isStarting else {
            AppLog.recorder.atDebug.debug("start: ignored (not idle or already starting)")
            return
        }
        isStarting = true
        defer { isStarting = false }

        let pickup = micPickup
        let bitRate = audioBitRate
        let forceBuiltIn = forceBuiltInMic
        let preferredUID = preferredInputUID
        let fileName = AudioFileStore.fileName(meetingID: meetingID)
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        AppLog.recorder.atDebug.debug("start: writing to \(fileName, privacy: .public)")

        do {
            // Heavy AVAudioSession + AVAudioEngine setup runs OFF the main actor
            // (see `setUpEngine`) so the UI — e.g. the recorder sheet animating
            // in — stays responsive while the engine spins up.
            try await setUpEngine(
                writingTo: url,
                pickup: pickup,
                bitRate: bitRate,
                forceBuiltIn: forceBuiltIn,
                preferredInputUID: preferredUID
            )
        } catch let error as AppError {
            AppLog.recorder.atError.error("start: setup threw AppError: \(error.errorDescription ?? "nil", privacy: .public)")
            teardownEngine()
            deactivateSession()
            throw error
        } catch {
            AppLog.recorder.atError.error("start: setup threw: \(error.localizedDescription, privacy: .public)")
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
        AppLog.recorder.atNotice.notice("start: engine running, state=recording")
    }

    /// Configure the audio session and start the engine. `nonisolated` + `async`
    /// so the (synchronously blocking) AVFoundation setup runs off the main
    /// actor instead of stalling the UI.
    private nonisolated func setUpEngine(
        writingTo url: URL,
        pickup: MicPickup,
        bitRate: Int,
        forceBuiltIn: Bool,
        preferredInputUID: String?
    ) async throws {
        try await configureSession(pickup: pickup, forceBuiltIn: forceBuiltIn, preferredInputUID: preferredInputUID)
        try await beginEngine(writingTo: url, bitRate: bitRate)
    }

    func pause() {
        AppLog.recorder.atInfo.info("pause: called state=\(String(describing: self.state), privacy: .public)")
        guard state == .recording else { return }
        sink.setPaused(true)
        accumulateElapsed()
        stopMetering()
        level = 0
        state = .paused
        notifyStateChanged()
    }

    func resume() {
        AppLog.recorder.atInfo.info("resume: called state=\(String(describing: self.state), privacy: .public)")
        guard state == .paused else { return }
        // An interruption may have stopped the engine while we were paused.
        if !engine.isRunning {
            do { try engine.start() } catch {
                AppLog.recorder.atError.error("resume: engine.start() failed: \(error.localizedDescription, privacy: .public)")
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
        AppLog.recorder.atNotice.notice("stop: called state=\(String(describing: self.state), privacy: .public) file=\(self.currentFileName ?? "nil", privacy: .public)")
        guard state != .idle, let fileName = currentFileName else {
            AppLog.recorder.atDebug.debug("stop: nothing to stop (idle or no file)")
            return nil
        }
        accumulateElapsed()
        stopMetering()
        teardownEngine()

        let duration = accumulated
        AppLog.recorder.atNotice.notice("stop: finalized file=\(fileName, privacy: .public) duration=\(duration, privacy: .public)s")
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
    private nonisolated func beginEngine(writingTo url: URL, bitRate: Int) async throws {
        let input = engine.inputNode
        // Keep the recorder on the standard input unit. VoiceProcessingIO can
        // block engine startup on some routes/devices, freezing this screen.
        try? input.setVoiceProcessingEnabled(false)

        // Right after a session activation that pulled in a Bluetooth route,
        // the accessory may still be mid-handshake switching from A2DP/idle
        // to HFP, so the input format can briefly read as 0/0. Poll briefly
        // before giving up rather than failing on the first read.
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount <= 0 {
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                format = input.outputFormat(forBus: 0)
                if format.sampleRate > 0, format.channelCount > 0 { break }
            }
        }
        AppLog.recorder.atDebug.debug("beginEngine: inputFormat sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            AppLog.recorder.atError.error("beginEngine: invalid input format (sampleRate or channelCount is 0)")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }

        // Encode at the fixed speech format rather than the mic's native one, so
        // the file size tracks the bit rate alone and a route change can't
        // invalidate the open file.
        guard let storageFormat = Self.storageProcessingFormat else {
            AppLog.recorder.atError.error("beginEngine: could not build the storage format")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Self.storageSampleRate,
            AVNumberOfChannelsKey: Int(Self.storageChannelCount),
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        // Kept from when the encoder saw the mic's native rate: some routes
        // (e.g. Bluetooth HFP hearing aids negotiating a narrowband link) had a
        // sample rate whose AAC encoder rejected an explicit bit rate this high,
        // throwing out of AVAudioFile's init. The fixed 24kHz mono format above
        // should never trip that, but failing a whole recording over an encoder
        // property is not worth the saved lines.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            AppLog.recorder.atError.error("beginEngine: AVAudioFile open failed with bitRate=\(bitRate, privacy: .public); retrying without explicit bit rate: \(error.localizedDescription, privacy: .public)")
            var fallbackSettings = settings
            fallbackSettings.removeValue(forKey: AVEncoderBitRateKey)
            do {
                file = try AVAudioFile(forWriting: url, settings: fallbackSettings)
            } catch {
                AppLog.recorder.atError.error("beginEngine: AVAudioFile open failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        guard let converter = Self.makeConverter(from: format, to: storageFormat) else {
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
        Self.installTap(on: input, format: format, sink: sink)
        tapInstalled = true
        tapFormat = format

        engine.prepare()
        do {
            try engine.start()
            AppLog.recorder.atDebug.debug("beginEngine: engine.start() succeeded, isRunning=\(self.engine.isRunning, privacy: .public)")
        } catch {
            AppLog.recorder.atError.error("beginEngine: engine.start() failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.audioError(
                NSLocalizedString("error.recorder_engine", comment: "Audio engine could not start")
            )
        }
    }

    /// Build the resampler that takes tap buffers to the stored format. Uses the
    /// highest-quality sample rate conversion (this runs on a fraction of a
    /// core for mono speech) and downmixes rather than dropping channels, so a
    /// stereo external mic keeps both sides' content.
    private nonisolated static func makeConverter(
        from input: AVAudioFormat,
        to output: AVAudioFormat
    ) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        if input.channelCount > output.channelCount {
            converter.downmix = true
        }
        return converter
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

    private nonisolated func configureSession(
        pickup: MicPickup,
        forceBuiltIn: Bool,
        preferredInputUID: String?
    ) async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try await activateSession(session)
            configureMicrophone(session, pickup: pickup, forceBuiltIn: forceBuiltIn, preferredInputUID: preferredInputUID)
            AppLog.recorder.atDebug.debug("configureSession: active route=\(session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","), privacy: .public) sampleRate=\(session.sampleRate, privacy: .public)")
        } catch {
            AppLog.recorder.atError.error("configureSession: failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.audioError(error.localizedDescription)
        }
    }

    /// Activate the session with a short retry/backoff. Requesting
    /// `.playAndRecord` while a Bluetooth headset is connected forces the
    /// accessory to switch profile (A2DP/idle → HFP), an asynchronous radio
    /// handshake that can make `setActive(true)` throw transiently while it's
    /// in flight. A brief retry rides out that window instead of failing the
    /// whole recording start on the first attempt.
    private nonisolated func activateSession(_ session: AVAudioSession, attempts: Int = 3) async throws {
        for attempt in 1...attempts {
            do {
                try session.setActive(true)
                return
            } catch {
                if attempt == attempts { throw error }
                AppLog.recorder.atInfo.info("activateSession: attempt \(attempt, privacy: .public) failed, retrying: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Select which physical input the session uses, then (for the built-in
    /// mic only) the polar pattern.
    ///
    /// Priority: an explicit `preferredInputUID` (from a per-recording
    /// microphone picker) always wins. Otherwise, if `forceBuiltIn` is set
    /// (Settings → always use the iPhone mic), the built-in mic is selected
    /// even with an accessory connected. Otherwise the system's own route
    /// choice is left alone — unless there's no external input at all, in
    /// which case the built-in mic is selected explicitly so its polar
    /// pattern can be steered.
    private nonisolated func configureMicrophone(
        _ session: AVAudioSession,
        pickup: MicPickup,
        forceBuiltIn: Bool,
        preferredInputUID: String?
    ) {
        guard let inputs = session.availableInputs else { return }

        if let uid = preferredInputUID, let match = inputs.first(where: { $0.uid == uid }) {
            try? session.setPreferredInput(match)
            if match.portType == .builtInMic {
                applyPolarPattern(to: match, pickup: pickup)
            }
            return
        }

        guard let builtIn = inputs.first(where: { $0.portType == .builtInMic }) else { return }
        let hasExternal = inputs.contains { $0.portType != .builtInMic }
        guard forceBuiltIn || !hasExternal else { return }

        try? session.setPreferredInput(builtIn)
        applyPolarPattern(to: builtIn, pickup: pickup)
    }

    /// Steer the built-in mic's polar pattern according to `micPickup`:
    /// whole-room favours an omnidirectional pickup (every participant), while
    /// focus-speaker favours cardioid (the person in front). Both fall back to
    /// subcardioid, then the hardware default.
    private nonisolated func applyPolarPattern(to builtIn: AVAudioSessionPortDescription, pickup: MicPickup) {
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
            AppLog.recorder.atDebug.debug("configureMicrophone: pickup=\(pickup.rawValue, privacy: .public) pattern=\(pattern.rawValue, privacy: .public) source=\(source.dataSourceName, privacy: .public)")
            return
        }
        AppLog.recorder.atDebug.debug("configureMicrophone: pickup=\(pickup.rawValue, privacy: .public) hardware default pattern (no preferred pattern available)")
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
        AppLog.recorder.atDebug.debug("startMetering: scheduling timer")
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
            AppLog.recorder.atDebug.debug("tick #\(self.tickCount, privacy: .public): elapsed=\(self.elapsed, privacy: .public) level=\(self.level, privacy: .public)")
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
        // The engine can be stopped out from under a live recording with NO
        // interruption notification: a configuration change (route/sample-rate
        // shuffle, seen around locking and unlocking the device) or a
        // media-services reset. Without these observers the recorder keeps
        // counting elapsed time while no buffers reach the file — silent
        // audio loss with only a frozen level meter as a symptom.
        center.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
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

    @objc private nonisolated func handleEngineConfigurationChange(_ note: Notification) {
        Task { @MainActor in self.recoverEngineIfNeeded(reason: "configuration change") }
    }

    @objc private nonisolated func handleMediaServicesReset(_ note: Notification) {
        Task { @MainActor in self.recoverEngineIfNeeded(reason: "media services reset") }
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
    private func recoverEngineIfNeeded(reason: String) {
        guard state == .recording, !engine.isRunning else { return }
        AppLog.recorder.atError.error("engine stopped mid-recording (\(reason, privacy: .public)); attempting restart")

        let current = engine.inputNode.outputFormat(forBus: 0)
        let formatUnchanged = tapFormat.map {
            $0.sampleRate == current.sampleRate && $0.channelCount == current.channelCount
        } ?? false

        if !formatUnchanged {
            AppLog.recorder.atNotice.notice("input format changed to \(current.sampleRate, privacy: .public)Hz/\(current.channelCount, privacy: .public)ch; rebuilding the tap")
            if !rebuildTapForCurrentInput(current) {
                pause()
                routeChangeMessage = NSLocalizedString(
                    "recorder.engine_stalled",
                    comment: "Recording paused because the system stopped the audio engine"
                )
                return
            }
        }

        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        do {
            try engine.start()
            AppLog.recorder.atNotice.notice("engine restarted in place after \(reason, privacy: .public)")
            return
        } catch {
            AppLog.recorder.atError.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
        }

        pause()
        routeChangeMessage = NSLocalizedString(
            "recorder.engine_stalled",
            comment: "Recording paused because the system stopped the audio engine"
        )
    }

    /// Re-point the tap and the sink's converter at a new input format, keeping
    /// the open output file. Returns false if either could not be rebuilt, in
    /// which case the caller pauses rather than capturing nothing.
    private func rebuildTapForCurrentInput(_ format: AVAudioFormat) -> Bool {
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        guard let targetFormat = sink.currentTargetFormat,
              let converter = Self.makeConverter(from: format, to: targetFormat) else {
            AppLog.recorder.atError.error("rebuildTap: could not build a converter for the new input format")
            return false
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        sink.replaceConverter(converter)
        Self.installTap(on: engine.inputNode, format: format, sink: sink)
        tapInstalled = true
        tapFormat = format
        return true
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

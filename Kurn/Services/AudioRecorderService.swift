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
import KurnCore
import Foundation
import Observation
import os

struct AudioRecordingResult {
    let fileName: String
    let duration: TimeInterval
    let highlights: [Highlight]
    let captureFailure: AudioSinkFailure?
}

enum AudioRecorderState: Equatable {
    case idle
    case recording
    case paused
}

/// Why `pause()` was invoked. Attached to the diagnostic log line so
/// Console / exported logs show WHY a recording paused — especially for
/// the automatic triggers that fire without any user interaction.
enum AudioRecorderPauseReason: String {
    case userToggle = "user toggled pause (in-app button or Live Activity pill)"
    case watchCommand = "Watch app pause command"
    case audioInterruption = "audio session interruption began"
    case engineRecoveryFailed = "engine recovery failed (tap rebuild after format change)"
    case engineRestartFailed = "engine recovery failed (engine.start() after rebuild)"
    case routeChanged = "input route became unavailable (oldDeviceUnavailable)"
    case sinkFailure = "audio conversion or file write failed"
    case captureStalled = "no output frames reached the recording file"
}

@MainActor
@Observable
final class AudioRecorderService: NSObject {
    typealias State = AudioRecorderState

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
    private(set) var captureFailure: AudioSinkFailure?
    private(set) var storageState: RecordingStorageState = .unknown
    @ObservationIgnored private var activeCaptureFailure: AudioSinkFailure?

    // The engine, sink and tap flag are touched by the off-main setup/teardown
    // path (see `setUpEngine`), so they are kept out of main-actor isolation and
    // out of observation. Access is serialized by the `state`/`isStarting` guards.
    // Typed as the protocol (defaulted to the real `AVFoundationCaptureEngine`)
    // so a test can script the session, the input format and system events.
    @ObservationIgnored private nonisolated let engine: any AudioCaptureEngine
    /// Thread-safe sink that owns the output file and the latest level. The input
    /// tap runs on a render thread, so it talks to the sink rather than to this
    /// main-actor object directly. Typed as the protocol (defaulted to the real
    /// `RecordingSink`) so a test can inject a fake that observes/fails writes.
    @ObservationIgnored private nonisolated let sink: any AudioSinkWriting
    @ObservationIgnored private let monotonicNow: @Sendable () -> TimeInterval
    @ObservationIgnored private let storageProbe: any RecordingStorageProbing
    @ObservationIgnored private var captureWatchdog: CaptureProgressWatchdog
    @ObservationIgnored private var storageMonitor: RecordingStorageMonitor?
    @ObservationIgnored private nonisolated(unsafe) var tapInstalled = false
    /// Input format the tap was created with, so the engine-stall recovery can
    /// tell a plain restart (same format) from one that needs the tap and the
    /// sink's converter rebuilt for a new input format.
    @ObservationIgnored private nonisolated(unsafe) var tapFormat: AVAudioFormat?
    /// True while `start` is asynchronously spinning up the engine, to block
    /// re-entrant start attempts during that window.
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var startCancellationRequested = false

    private var meterTimer: Timer?
    /// Counts metering ticks so we can log progress without flooding the console.
    private var tickCount = 0
    private var currentFileName: String?
    private var currentFileURL: URL?
    /// Accumulated time across pause cycles plus the active span.
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    /// Timestamps marked during the current recording, chronological (only
    /// appended while `state == .recording`, so append order == time order).
    private(set) var highlights: [Highlight] = []
    @ObservationIgnored var onStateChanged: ((State, TimeInterval) -> Void)?
    /// Fired on every metering tick (~50ms) while recording, for low-latency
    /// mirroring (e.g. to the Watch app). Not used for UI state transitions.
    @ObservationIgnored var onLevelChanged: ((Float) -> Void)?
    /// Fired synchronously right after a highlight is captured — unlike
    /// `onStateChanged`, marking a highlight does not change `state`/`elapsed`,
    /// so this is the only signal callers get to re-push the Lock Screen /
    /// Watch highlight count.
    @ObservationIgnored var onHighlightAdded: ((Highlight) -> Void)?
    /// Fired with every raw captured buffer (e.g. for live transcription
    /// preview). Called on the audio render thread, like the tap itself —
    /// `nonisolated(unsafe)` so setting it doesn't require the main actor.
    @ObservationIgnored nonisolated(unsafe) var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Whether the user was recording when an interruption began, so we can
    /// decide whether to auto-resume when it ends.
    private var wasRecordingBeforeInterruption = false

    init(
        engine: any AudioCaptureEngine = AVFoundationCaptureEngine(),
        sink: any AudioSinkWriting = RecordingSink(),
        stallInterval: TimeInterval = 2,
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        storageProbe: any RecordingStorageProbing = SystemRecordingStorageProbe()
    ) {
        self.engine = engine
        self.sink = sink
        self.monotonicNow = monotonicNow
        self.storageProbe = storageProbe
        self.captureWatchdog = CaptureProgressWatchdog(stallInterval: stallInterval)
        super.init()
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleCaptureEvent(event) }
        }
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
    func start(fileName: String) async throws {
        AppLog.recorder.atNotice.notice("start: requested for file=\(fileName, privacy: .public) currentState=\(String(describing: self.state), privacy: .public)")
        guard state == .idle, !isStarting else {
            AppLog.recorder.atError.error("start: rejected (not idle or already starting)")
            throw AppError.audioError(NSLocalizedString(
                "recorder.already_active",
                comment: "A recording is already starting or active"
            ))
        }
        isStarting = true
        startCancellationRequested = false
        captureFailure = nil
        activeCaptureFailure = nil
        defer { isStarting = false }

        let pickup = micPickup
        let bitRate = audioBitRate
        let forceBuiltIn = forceBuiltInMic
        let preferredUID = preferredInputUID
        let directory = try AudioFileStore.ensureRecordingsDirectory()
        try prepareStorageForRecording(bitRate: bitRate, directory: directory)
        let url = directory.appendingPathComponent(fileName)
        currentFileName = fileName
        currentFileURL = url
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
            try Task.checkCancellation()
            if startCancellationRequested { throw CancellationError() }
        } catch let error as AppError {
            // H9 PR 22, item 5: `logCode` is content-free; `errorDescription`
            // can interpolate a raw underlying error's own
            // `localizedDescription` for several `AppError` cases, which
            // must not reach a `.public` log line unredacted.
            AppLog.recorder.atError.error("start: setup threw AppError code=\(error.logCode, privacy: .public) detail=\(error.privateContext ?? "", privacy: .private)")
            cleanUpFailedStart(fileName: fileName)
            throw error
        } catch is CancellationError {
            cleanUpFailedStart(fileName: fileName)
            throw CancellationError()
        } catch {
            AppLog.recorder.atError.error("start: setup threw code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            cleanUpFailedStart(fileName: fileName)
            throw AppError.audioError(error.localizedDescription)
        }

        // Back on the main actor: publish state and start the metering timer.
        self.accumulated = 0
        self.segmentStart = Date()
        self.elapsed = 0
        self.highlights = []
        self.routeChangeMessage = nil
        self.captureWatchdog.reset(
            writtenFrames: sink.snapshot.writtenOutputFrames,
            now: monotonicNow()
        )
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

    private func cleanUpFailedStart(fileName: String) {
        teardownEngine()
        AudioFileStore.delete(fileName: fileName)
        resetRuntimeState()
        engine.deactivateSession()
    }

    typealias PauseReason = AudioRecorderPauseReason

    func pause(reason: PauseReason) {
        AppLog.recorder.atNotice.notice("pause: called state=\(String(describing: self.state), privacy: .public) reason=\(reason.rawValue, privacy: .public)")
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
        let retryingStall = activeCaptureFailure == .stalled
        guard activeCaptureFailure == nil || retryingStall else {
            _ = pollSinkStatus()
            return
        }
        guard sink.snapshot.firstFailure == nil else {
            _ = pollSinkStatus()
            return
        }
        if retryingStall {
            if engine.isRunning { engine.stop() }
            guard let currentFormat = engine.inputFormat, rebuildTapForCurrentInput(currentFormat) else {
                AppLog.recorder.atError.error("resume: capture watchdog retry could not rebuild the input tap")
                return
            }
            engine.reactivateSession()
            engine.prepare()
        }
        // An interruption may have stopped the engine while we were paused.
        if !engine.isRunning {
            do { try engine.start() } catch {
                AppLog.recorder.atError.error("resume: engine.start() failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                return
            }
        }
        activeCaptureFailure = nil
        sink.setPaused(false)
        captureWatchdog.reset(
            writtenFrames: sink.snapshot.writtenOutputFrames,
            now: monotonicNow()
        )
        segmentStart = Date()
        routeChangeMessage = nil
        state = .recording
        notifyStateChanged()
        startMetering()
    }

    /// Mark the current instant as a highlight. No-op unless actively
    /// recording (mirrors `pause()`'s state guard) — marking while paused has
    /// no "current instant" to capture, unlike pause/resume/stop which operate
    /// on the whole session.
    func markHighlight() {
        guard state == .recording, let start = segmentStart else { return }
        let timestamp = accumulated + Date().timeIntervalSince(start)
        let highlight = Highlight(timestamp: timestamp)
        highlights.append(highlight)
        AppLog.recorder.atNotice.notice("markHighlight: added at \(timestamp, privacy: .public)s, count=\(self.highlights.count, privacy: .public)")
        onHighlightAdded?(highlight)
    }

    /// Stop and finalize. Returns the file name, total duration, highlights, and
    /// any latched capture failure, or nil if nothing was recorded. The session
    /// is deactivated afterwards.
    @discardableResult
    func stop() -> AudioRecordingResult? {
        AppLog.recorder.atNotice.notice("stop: called state=\(String(describing: self.state), privacy: .public) file=\(self.currentFileName ?? "nil", privacy: .public)")
        guard state != .idle, let fileName = currentFileName else {
            AppLog.recorder.atDebug.debug("stop: nothing to stop (idle or no file)")
            return nil
        }
        accumulateElapsed()
        stopMetering()
        teardownEngine()
        _ = pollSinkStatus()

        let duration = accumulated
        let capturedHighlights = highlights
        let finalCaptureFailure = captureFailure ?? sink.snapshot.firstFailure
        let outcome = finalCaptureFailure == nil ? "ready" : "partial"
        AppLog.recorder.atNotice.notice("stop: outcome=\(outcome, privacy: .public) file=\(fileName, privacy: .public) duration=\(duration, privacy: .public)s highlights=\(capturedHighlights.count, privacy: .public)")
        resetRuntimeState()
        engine.deactivateSession()
        return AudioRecordingResult(
            fileName: fileName,
            duration: duration,
            highlights: capturedHighlights,
            captureFailure: finalCaptureFailure
        )
    }

    /// Abort the current recording and delete its partial file.
    func cancel() {
        if isStarting {
            startCancellationRequested = true
            return
        }
        guard let fileName = currentFileName else { return }
        stopMetering()
        teardownEngine()
        AudioFileStore.delete(fileName: fileName)
        resetRuntimeState()
        engine.deactivateSession()
    }

    private func resetRuntimeState() {
        currentFileName = nil
        currentFileURL = nil
        state = .idle
        level = 0
        elapsed = 0
        accumulated = 0
        segmentStart = nil
        highlights = []
        notifyStateChanged()
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

    private nonisolated func teardownEngine() {
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
        let snapshot = sink.snapshot
        if pollSinkStatus(snapshot: snapshot) { return }
        guard engine.isRunning else {
            recoverEngineIfNeeded(reason: "capture watchdog")
            if state == .recording {
                captureWatchdog.reset(
                    writtenFrames: sink.snapshot.writtenOutputFrames,
                    now: monotonicNow()
                )
            }
            return
        }
        if pollCaptureProgress(snapshot: snapshot, now: monotonicNow()) { return }
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
        if tickCount == 1 || tickCount % 100 == 0 {
            refreshStorage(snapshot: snapshot)
        }
        if tickCount == 1 || tickCount % 20 == 0 {
            AppLog.recorder.atDebug.debug("tick #\(self.tickCount, privacy: .public): elapsed=\(self.elapsed, privacy: .public) level=\(self.level, privacy: .public)")
        }
    }

    func prepareStorageForRecording(bitRate: Int, directory: URL) throws {
        storageMonitor = nil
        let monitor = RecordingStorageMonitor(bitRate: bitRate)
        let state = monitor.assess(
            capacity: storageProbe.capacity(at: directory),
            fileSize: nil,
            writtenOutputFrames: 0
        )
        storageState = state
        if let error = monitor.startError(for: state) { throw error }
        storageMonitor = monitor
    }

    func refreshStorage(snapshot: AudioSinkSnapshot, fileURL: URL? = nil) {
        guard let storageMonitor, let fileURL = fileURL ?? currentFileURL else { return }
        storageState = storageMonitor.assess(
            capacity: storageProbe.capacity(at: fileURL.deletingLastPathComponent()),
            fileSize: storageProbe.fileSize(at: fileURL),
            writtenOutputFrames: snapshot.writtenOutputFrames
        )
    }

    @discardableResult
    func pollSinkStatus(snapshot: AudioSinkSnapshot? = nil) -> Bool {
        let snapshot = snapshot ?? sink.snapshot
        guard let failure = snapshot.firstFailure, activeCaptureFailure == nil else { return false }
        if captureFailure == nil {
            captureFailure = failure
        }
        activeCaptureFailure = failure
        routeChangeMessage = NSLocalizedString(
            "recorder.write_failed",
            comment: "Recording paused because captured audio could not be written"
        )
        if state == .recording {
            pause(reason: .sinkFailure)
        }
        AppLog.recorder.atError.error(
            "capture sink failed code=\(failure.rawValue, privacy: .public) attemptedInputFrames=\(snapshot.attemptedInputFrames, privacy: .public) writtenOutputFrames=\(snapshot.writtenOutputFrames, privacy: .public)"
        )
        CaptureReliability.sinkFailed(fileName: currentFileName, failure: failure)
        return true
    }

    @discardableResult
    func pollCaptureProgress(snapshot: AudioSinkSnapshot, now: TimeInterval) -> Bool {
        guard captureWatchdog.hasStalled(
            writtenFrames: snapshot.writtenOutputFrames,
            now: now
        ) else { return false }
        return reportCaptureStall(snapshot: snapshot)
    }

    @discardableResult
    func reportCaptureStall(snapshot: AudioSinkSnapshot? = nil) -> Bool {
        guard activeCaptureFailure == nil else { return false }
        let snapshot = snapshot ?? sink.snapshot
        if captureFailure == nil {
            captureFailure = .stalled
        }
        activeCaptureFailure = .stalled
        routeChangeMessage = NSLocalizedString(
            "recorder.capture_stalled",
            comment: "Recording paused because frames stopped reaching the file"
        )
        if state == .recording {
            pause(reason: .captureStalled)
        }
        AppLog.recorder.atError.error(
            "capture watchdog stalled writtenOutputFrames=\(snapshot.writtenOutputFrames, privacy: .public) attemptedInputFrames=\(snapshot.attemptedInputFrames, privacy: .public)"
        )
        CaptureReliability.sinkFailed(fileName: currentFileName, failure: .stalled)
        return true
    }

    private func notifyStateChanged() {
        onStateChanged?(state, elapsed)
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
    private func recoverEngineIfNeeded(reason: String) {
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

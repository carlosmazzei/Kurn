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

@MainActor
@Observable
final class AudioRecorderService: NSObject {
    typealias State = AudioRecorderState

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
    var routeChangeMessage: String?
    private(set) var captureFailure: AudioSinkFailure?
    private(set) var storageState: RecordingStorageState = .unknown
    @ObservationIgnored private var activeCaptureFailure: AudioSinkFailure?

    // The engine, sink and tap flag are touched by the off-main setup/teardown
    // path (see `setUpEngine`), so they are kept out of main-actor isolation and
    // out of observation. Access is serialized by the `state`/`isStarting` guards.
    // Typed as the protocol (defaulted to the real `AVFoundationCaptureEngine`)
    // so a test can script the session, the input format and system events.
    @ObservationIgnored nonisolated let engine: any AudioCaptureEngine
    /// Thread-safe sink that owns the output file and the latest level. The input
    /// tap runs on a render thread, so it talks to the sink rather than to this
    /// main-actor object directly. Typed as the protocol (defaulted to the real
    /// `RecordingSink`) so a test can inject a fake that observes/fails writes.
    @ObservationIgnored nonisolated let sink: any AudioSinkWriting
    @ObservationIgnored private let monotonicNow: @Sendable () -> TimeInterval
    @ObservationIgnored private let storageProbe: any RecordingStorageProbing
    @ObservationIgnored private let microphonePermission: @Sendable () async -> Bool
    @ObservationIgnored private var captureWatchdog: CaptureProgressWatchdog
    @ObservationIgnored private var storageMonitor: RecordingStorageMonitor?
    @ObservationIgnored nonisolated(unsafe) var tapInstalled = false
    /// Input format the tap was created with, so the engine-stall recovery can
    /// tell a plain restart (same format) from one that needs the tap and the
    /// sink's converter rebuilt for a new input format.
    @ObservationIgnored nonisolated(unsafe) var tapFormat: AVAudioFormat?
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
    /// Photos captured during the current recording, chronological (only
    /// appended while `state == .recording`, same guard as `highlights`).
    private(set) var photos: [CapturedPhotoRecord] = []
    @ObservationIgnored var onStateChanged: ((State, TimeInterval) -> Void)?
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
    var wasRecordingBeforeInterruption = false

    init(
        engine: any AudioCaptureEngine = AVFoundationCaptureEngine(),
        sink: any AudioSinkWriting = RecordingSink(),
        stallInterval: TimeInterval = 2,
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        storageProbe: any RecordingStorageProbing = SystemRecordingStorageProbe(),
        microphonePermission: @escaping @Sendable () async -> Bool = AudioRecorderService.systemMicrophonePermission
    ) {
        self.engine = engine
        self.sink = sink
        self.monotonicNow = monotonicNow
        self.storageProbe = storageProbe
        self.microphonePermission = microphonePermission
        self.captureWatchdog = CaptureProgressWatchdog(stallInterval: stallInterval)
        super.init()
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleCaptureEvent(event) }
        }
    }

    // MARK: - Permissions

    /// Request microphone permission. Returns true if granted.
    func requestMicrophonePermission() async -> Bool {
        let granted = await microphonePermission()
        AppLog.recorder.atInfo.info("requestMicrophonePermission: granted=\(granted, privacy: .public)")
        return granted
    }

    /// Production permission path: the system prompt via `AVAudioApplication`.
    nonisolated static func systemMicrophonePermission() async -> Bool {
        let current = AVAudioApplication.shared.recordPermission
        AppLog.recorder.atDebug.debug("requestMicrophonePermission: current=\(String(describing: current), privacy: .public)")
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
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
        self.photos = []
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

    /// Register a photo already written to disk (by `PhotoFileStore`) at the
    /// current instant. No-op unless actively recording, same guard as
    /// `markHighlight()` — a caller that captures while paused must delete the
    /// file itself, since there is no "current instant" to attach it to.
    /// Returns the record so the caller can react (e.g. haptic feedback), or
    /// `nil` when the photo could not be registered.
    @discardableResult
    func registerPhoto(fileName: String) -> CapturedPhotoRecord? {
        guard state == .recording, let start = segmentStart else { return nil }
        let timestamp = accumulated + Date().timeIntervalSince(start)
        let record = CapturedPhotoRecord(id: UUID(), fileName: fileName, capturedAt: timestamp, createdAt: Date())
        photos.append(record)
        AppLog.recorder.atNotice.notice("registerPhoto: added at \(timestamp, privacy: .public)s, count=\(self.photos.count, privacy: .public)")
        return record
    }

    /// Stop and finalize. Returns the file name, total duration, highlights,
    /// captured photos, and any latched capture failure, or nil if nothing was
    /// recorded. The session is deactivated afterwards.
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
        let capturedPhotos = photos
        let finalCaptureFailure = captureFailure ?? sink.snapshot.firstFailure
        let outcome = finalCaptureFailure == nil ? "ready" : "partial"
        AppLog.recorder.atNotice.notice("stop: outcome=\(outcome, privacy: .public) file=\(fileName, privacy: .public) duration=\(duration, privacy: .public)s highlights=\(capturedHighlights.count, privacy: .public) photos=\(capturedPhotos.count, privacy: .public)")
        resetRuntimeState()
        engine.deactivateSession()
        return AudioRecordingResult(
            fileName: fileName,
            duration: duration,
            highlights: capturedHighlights,
            photos: capturedPhotos,
            captureFailure: finalCaptureFailure
        )
    }

    /// Abort the current recording and delete its partial file and any photos
    /// captured during it — a cancelled recording leaves nothing behind.
    func cancel() {
        if isStarting {
            startCancellationRequested = true
            return
        }
        guard let fileName = currentFileName else { return }
        stopMetering()
        teardownEngine()
        AudioFileStore.delete(fileName: fileName)
        for photo in photos {
            PhotoFileStore.delete(fileName: photo.fileName)
        }
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
        // The capture journal writes a second copy at the same bit rate.
        let monitor = RecordingStorageMonitor(bitRate: bitRate * CaptureJournal.storageMultiplier)
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
        sink.flushReliabilityEvents()
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
}

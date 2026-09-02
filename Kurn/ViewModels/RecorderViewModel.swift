//
//  RecorderViewModel.swift
//  Kurn
//
//  Drives RecorderView: owns the AudioRecorderService, surfaces permission and
//  error state, and persists a finished segment as a `Recording` in SwiftData.
//

import AVFoundation
import Foundation
import KurnCore
import Observation
import os
import SwiftData

/// Recording-preference bundle for `RecorderViewModel.init`, grouping
/// settings-derived options so the initializer doesn't accumulate a
/// parameter per preference.
struct RecorderOptions {
    var micPickup: MicPickup = .wholeRoom
    var audioQuality: AudioQuality = .high
    var alwaysUseBuiltInMic: Bool = false
    var liveTranscriptionEnabled: Bool = false
    var liveTranscriptionModelsConsented: Bool = false
    var largeTransferPolicy: LargeTransferPolicy = .wifiOnly
    var hideLiveActivityMeetingTitle: Bool = true
}

/// One entry in the microphone picker shown before recording starts when more
/// than one input is available and `alwaysUseBuiltInMic` is off.
struct MicInputOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isBuiltIn: Bool
}

@MainActor
@Observable
final class RecorderViewModel {
    let recorder: AudioRecorderService
    let liveTranscription: LiveTranscriptionService

    var error: AppError?
    var permissionDenied = false
    /// Set once a recording has been saved so the view can dismiss.
    var didSaveRecording = false
    /// True while `startRecording()` is setting up the audio session/engine
    /// (including any Bluetooth-route retry) but recording hasn't begun yet —
    /// `recorder.state` stays `.idle` for that whole window, so the view needs
    /// this separate flag to show a "connecting" cue instead of looking stuck.
    private(set) var isStarting = false
    /// Candidate inputs awaiting the user's choice before recording starts;
    /// empty once resolved — either the user picked one, only one input was
    /// available, or `alwaysUseBuiltInMic` skipped the prompt entirely.
    private(set) var micChoices: [MicInputOption] = []

    private let meeting: Meeting
    private let modelContext: ModelContext
    private let defaultMode: TranscriptionMode
    private let alwaysUseBuiltInMic: Bool
    private let liveTranscriptionEnabled: Bool
    private let liveTranscriptionModelsConsented: Bool
    private let largeTransferPolicy: LargeTransferPolicy
    private let hideLiveActivityMeetingTitle: Bool
    private let fileFinalizer: any RecordingFileFinalizing
    private let lifecycleSaver: any RecordingLifecycleSaving
    private var activeRecording: Recording?
    private var cancellationRequested = false
    private var micChoiceContinuation: CheckedContinuation<String?, Never>?
    private var finishAfterErrorDismissal = false
    private let lockScreenController = LockScreenRecordingController()
    /// Invoked once a recording is actually persisted (not on the "ignored"
    /// no-result/too-short paths, and not on a save failure) — lets the caller
    /// bump the local usage counter without threading `AppSettings` through
    /// this view model.
    private let onRecordingSaved: () -> Void

    init(
        meeting: Meeting,
        modelContext: ModelContext,
        defaultMode: TranscriptionMode,
        options: RecorderOptions = RecorderOptions(),
        recorder: AudioRecorderService = AudioRecorderService(),
        liveTranscription: LiveTranscriptionService = LiveTranscriptionService(),
        fileFinalizer: any RecordingFileFinalizing = RecordingFileFinalizer(),
        lifecycleSaver: any RecordingLifecycleSaving = ModelContextRecordingLifecycleSaver(),
        onRecordingSaved: @escaping () -> Void = {}
    ) {
        self.meeting = meeting
        self.modelContext = modelContext
        self.defaultMode = defaultMode
        self.recorder = recorder
        self.liveTranscription = liveTranscription
        self.fileFinalizer = fileFinalizer
        self.lifecycleSaver = lifecycleSaver
        self.alwaysUseBuiltInMic = options.alwaysUseBuiltInMic
        self.liveTranscriptionEnabled = options.liveTranscriptionEnabled
        self.liveTranscriptionModelsConsented = options.liveTranscriptionModelsConsented
        self.largeTransferPolicy = options.largeTransferPolicy
        self.hideLiveActivityMeetingTitle = options.hideLiveActivityMeetingTitle
        self.onRecordingSaved = onRecordingSaved
        self.recorder.micPickup = options.micPickup
        self.recorder.audioBitRate = options.audioQuality.bitRate
        self.recorder.forceBuiltInMic = options.alwaysUseBuiltInMic
        self.recorder.onStateChanged = { [weak self] state, elapsed in
            self?.lockScreenController.update(state: state, elapsed: elapsed, highlightCount: self?.recorder.highlights.count ?? 0)
            self?.pushWatchState(state: state, elapsed: elapsed)
        }
        self.recorder.onLevelChanged = { level in
            PhoneSessionController.shared.pushLevel(level)
        }
        // Marking a highlight doesn't change `state`/`elapsed`, so
        // `onStateChanged` above never fires for it — this is the only signal
        // that re-pushes the updated count to the Lock Screen and the Watch.
        self.recorder.onHighlightAdded = { [weak self] _ in
            guard let self else { return }
            self.lockScreenController.update(
                state: self.recorder.state,
                elapsed: self.recorder.elapsed,
                highlightCount: self.recorder.highlights.count
            )
            self.pushWatchState(state: self.recorder.state, elapsed: self.recorder.elapsed)
        }
        if options.liveTranscriptionEnabled {
            // Capture the service directly (not via `self`) so this closure,
            // invoked on the tap's real-time render thread, isn't inferred as
            // main-actor isolated — `append` is `nonisolated` precisely so it
            // can be called from there.
            let live = liveTranscription
            self.recorder.onAudioBuffer = { buffer in
                live.append(buffer)
            }
        }
    }

    var livePartialText: String { liveTranscription.partialText }
    var isLiveTranscriptionActive: Bool { liveTranscription.isActive }
    var isLiveTranscriptionLoading: Bool { liveTranscription.isLoading }
    var isLiveTranscriptionUnavailable: Bool { liveTranscription.isUnavailable }
    /// True whenever the recorder was launched with the live preview enabled —
    /// drives whether the UI reserves space for the preview area (loading,
    /// listening, or unavailable messages) even before models finish loading.
    var isLiveTranscriptionRequested: Bool { liveTranscriptionEnabled }

    private func pushWatchState(state: AudioRecorderService.State, elapsed: TimeInterval) {
        PhoneSessionController.shared.pushState(
            state: state,
            meetingTitle: displayTitle,
            accumulatedElapsed: elapsed,
            referenceDate: Date(),
            isAvailable: state != .idle,
            highlightCount: recorder.highlights.count
        )
    }

    /// Meeting title shown on the Lock Screen Live Activity and the paired
    /// Watch — both are glanceable surfaces, so both honor the same
    /// redaction setting.
    private var displayTitle: String {
        hideLiveActivityMeetingTitle
            ? NSLocalizedString("recording.live_activity.generic_title", comment: "Generic Live Activity title")
            : meeting.title
    }

    var state: AudioRecorderService.State { recorder.state }
    var level: Float { recorder.level }
    var elapsed: TimeInterval { recorder.elapsed }
    var routeMessage: String? { recorder.routeChangeMessage ?? recorder.storageState.userMessage }
    var highlightCount: Int { recorder.highlights.count }

    /// Editable meeting title, surfaced as the recorder's "Add title…" field.
    var meetingTitle: String {
        get { meeting.title }
        set { meeting.title = newValue }
    }

    /// Entry point from the recorder sheet: resolve which microphone to use —
    /// asking the user via `micChoices` when more than one input is available
    /// and Settings isn't forcing the built-in mic — then begin recording.
    func prepareToRecord() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        if !alwaysUseBuiltInMic {
            let session = AVAudioSession.sharedInstance()
            // `availableInputs` only lists a Bluetooth accessory once the
            // session's category allows Bluetooth HFP input. On a fresh
            // launch the session is still at its default category (no
            // recording has configured it yet), so without this the very
            // first recording only ever sees the built-in mic and silently
            // skips the picker — setting the category here (without
            // activating) is enough for the query below to see a connected
            // accessory too, even before `AudioRecorderService` runs its own
            // (activating) `configureSession`.
            try? session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            let inputs = session.availableInputs ?? []
            if inputs.count > 1 {
                AppLog.recorderUI.atDebug.debug("prepareToRecord: \(inputs.count, privacy: .public) inputs available, asking user")
                let uid = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    storeMicChoiceContinuation(continuation)
                    micChoices = inputs.map {
                        MicInputOption(id: $0.uid, name: $0.portName, isBuiltIn: $0.portType == .builtInMic)
                    }
                }
                recorder.preferredInputUID = uid
            }
        }
        await startRecording()
    }

    /// Resolve the pending microphone choice (or `nil` to defer to the system
    /// default) and unblock `prepareToRecord()`. Called from the picker UI,
    /// including its cancel/dismiss path.
    func chooseMic(uid: String?) {
        micChoices = []
        micChoiceContinuation?.resume(returning: uid)
        micChoiceContinuation = nil
    }

    /// Stores `continuation` as the pending mic choice, first resolving any
    /// continuation already pending (to `nil`, "use the system default") so
    /// a second concurrent request can never silently leak the first —
    /// nothing would otherwise ever resume it, hanging that earlier call
    /// forever (H8 PR 18). `internal` rather than `private` so `KurnTests`
    /// can drive it directly: the real trigger
    /// (`AVAudioSession.availableInputs.count > 1`) isn't reproducible
    /// against the simulator's single built-in mic.
    func storeMicChoiceContinuation(_ continuation: CheckedContinuation<String?, Never>) {
        if let stale = micChoiceContinuation {
            AppLog.recorderUI.atNotice.notice("prepareToRecord: a mic choice was already pending; resolving it to the default before starting a new one")
            stale.resume(returning: nil)
        }
        micChoiceContinuation = continuation
    }

    #if DEBUG
    /// Test-only: whether a mic-choice continuation is currently pending,
    /// so a test can poll for it to actually be stored before simulating a
    /// second concurrent request, instead of guessing a fixed delay.
    var hasPendingMicChoiceContinuationForTesting: Bool { micChoiceContinuation != nil }
    #endif

    func prepareCaptureOwnership() throws -> Recording {
        guard meeting.modelContext === modelContext else {
            throw AppError.persistenceFailed(NSLocalizedString(
                "recorder.meeting_unavailable",
                comment: "The meeting is unavailable in the active store"
            ))
        }
        let recordingID = UUID()
        let recording = Recording(
            id: recordingID,
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id, recordingID: recordingID),
            duration: 0,
            transcriptionMode: defaultMode,
            captureState: .preparing
        )
        modelContext.insert(recording)
        do {
            try lifecycleSaver.save(modelContext)
            activeRecording = recording
            return recording
        } catch {
            modelContext.delete(recording)
            throw AppError.persistenceFailed(error.localizedDescription)
        }
    }

    private func prepareCaptureOwnershipOrPresentError() -> Recording? {
        do {
            return try prepareCaptureOwnership()
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .persistenceFailed(error.localizedDescription)
        }
        return nil
    }

    private func canBeginCapture() async -> Bool {
        guard activeRecording == nil else {
            error = .audioError(NSLocalizedString(
                "recorder.already_active",
                comment: "A recording is already starting or active"
            ))
            return false
        }
        AppLog.recorderUI.atNotice.notice("startRecording: begin, requesting permission")
        guard await recorder.requestMicrophonePermission() else {
            AppLog.recorderUI.atError.error("startRecording: permission denied")
            permissionDenied = true
            return false
        }
        return true
    }

    /// Request permission (if needed) and begin recording.
    func startRecording() async {
        guard await canBeginCapture() else { return }
        cancellationRequested = false
        isStarting = true
        defer { isStarting = false }
        guard let recording = prepareCaptureOwnershipOrPresentError() else { return }
        let fileName = recording.fileName

        let liveLanguage = meeting.language
        let liveStartTask: Task<Void, Never>? = liveTranscriptionEnabled && liveTranscriptionModelsConsented
            ? Task { @MainActor [weak self] in
                guard let self else { return }
                await liveTranscription.start(
                    language: liveLanguage,
                    modelsConsented: liveTranscriptionModelsConsented,
                    policy: largeTransferPolicy
                )
            }
            : nil
        do {
            try await recorder.start(fileName: fileName)
            recording.captureState = .recording
            do {
                try lifecycleSaver.save(modelContext)
            } catch {
                let result = recorder.stop()
                finalizeCapture(recording, result: result, forcedReason: .interruptedDuringCapture)
                throw AppError.persistenceFailed(error.localizedDescription)
            }
            lockScreenController.start(
                title: displayTitle,
                state: recorder.state,
                elapsed: recorder.elapsed,
                highlightCount: 0
            )
            RecordingCommandRouter.shared.register(
                onTogglePause: { [weak self] in self?.togglePause() },
                onPause: { [weak self] in
                    AppLog.recorderUI.atNotice.notice("onPause: Watch-issued pause invoked directly")
                    self?.recorder.pause(reason: .watchCommand)
                },
                onResume: { [weak self] in self?.recorder.resume() },
                onStop: { [weak self] in self?.stopAndSave() ?? false },
                onHighlight: { [weak self] in self?.markHighlight() }
            )
            await liveStartTask?.value
            AppLog.recorderUI.atInfo.info("startRecording: done, state=\(String(describing: self.recorder.state), privacy: .public)")
        } catch let appError as AppError {
            if cancellationRequested { return }
            // H9 PR 22, item 5: `logCode` is content-free; `errorDescription`
            // can interpolate a raw underlying error's own
            // `localizedDescription` for several `AppError` cases, which
            // must not reach a `.public` log line unredacted.
            AppLog.recorderUI.atError.error("startRecording: AppError code=\(appError.logCode, privacy: .public) detail=\(appError.privateContext ?? "", privacy: .private)")
            recoverFailedStart(recording)
            await liveStartTask?.value
            if liveTranscriptionEnabled { await liveTranscription.stop() }
            if error == nil { error = appError }
        } catch is CancellationError {
            if !cancellationRequested { recoverFailedStart(recording) }
            if liveTranscriptionEnabled { await liveTranscription.stop() }
        } catch {
            if cancellationRequested { return }
            AppLog.recorderUI.atError.error("startRecording: error: \(error.localizedDescription, privacy: .public)")
            recoverFailedStart(recording)
            await liveStartTask?.value
            if liveTranscriptionEnabled { await liveTranscription.stop() }
            if self.error == nil { self.error = .audioError(error.localizedDescription) }
        }
    }

    func markHighlight() {
        recorder.markHighlight()
    }

    func togglePause() {
        AppLog.recorderUI.atInfo.info("togglePause: state=\(String(describing: self.recorder.state), privacy: .public)")
        switch recorder.state {
        case .recording: recorder.pause(reason: .userToggle)
        case .paused: recorder.resume()
        case .idle: break
        }
    }

    /// Stop the optional live-transcription preview. Fired from the synchronous
    /// teardown paths (`stopAndSave`/`cancel`), which the Watch / Live Activity
    /// command router invokes through a non-async closure, so the stop can't be
    /// awaited here. It captures the service directly — not `self` — so finishing
    /// the ASR engine never keeps the whole view model (and its model context and
    /// recorder) alive past teardown; only the small preview service is retained
    /// until it finishes. The finalized preview text isn't persisted (the real
    /// transcript comes from the full pipeline later), so not awaiting is safe.
    private func stopLiveTranscription() {
        guard liveTranscriptionEnabled else { return }
        let live = liveTranscription
        Task { await live.stop() }
    }

    /// Stop, save the segment to SwiftData, and flag completion. Returns
    /// whether the recording was durably finalized to disk — `false` for a
    /// recovery-needed outcome or a persistence failure, `true` otherwise
    /// (including "no active recording", a legitimate no-op). Consumed by
    /// `RecordingCommandRouter`'s Watch command reply (H8 PR 20), since this
    /// method already runs entirely synchronously, finalization included, so
    /// the outcome is known before it returns rather than discovered later.
    @discardableResult
    func stopAndSave() -> Bool {
        AppLog.recorderUI.atNotice.notice("stopAndSave: called state=\(String(describing: self.recorder.state), privacy: .public)")
        stopLiveTranscription()
        guard let recording = activeRecording else {
            finishExternalRecordingState()
            return true
        }
        recording.captureState = .finalizing
        do {
            try lifecycleSaver.save(modelContext)
        } catch {
            AppLog.persistence.atError.error("recording: finalizing transition save failed")
        }
        let result = recorder.stop()
        let finalized = finalizeCapture(recording, result: result)
        finishExternalRecordingState()
        return finalized
    }

    @discardableResult
    func finalizeCapture(
        _ recording: Recording,
        result: AudioRecordingResult?,
        forcedReason: CaptureRecoveryReason? = nil
    ) -> Bool {
        do {
            let metadata = try fileFinalizer.finalize(fileName: recording.fileName)
            let recoveryReason = forcedReason ?? result?.captureFailure.map(CaptureRecoveryReason.init)
            if metadata.duration < 0.5, recoveryReason == nil {
                return discardShortRecording(recording)
            }
            recording.duration = metadata.duration
            recording.fileSize = metadata.fileSize
            recording.highlights = result?.highlights ?? recording.highlights
            recording.captureState = recoveryReason == nil ? .ready : .recoveryNeeded
            recording.captureRecoveryReason = recoveryReason
        } catch let finalizationError as RecordingFileFinalizationError {
            recording.captureState = .recoveryNeeded
            recording.captureRecoveryReason = finalizationError.recoveryReason
        } catch {
            recording.captureState = .recoveryNeeded
            recording.captureRecoveryReason = .unreadableFile
        }

        do {
            try lifecycleSaver.save(modelContext)
            if recording.fileSize > 0 { onRecordingSaved() }
            activeRecording = nil
        } catch {
            self.error = .persistenceFailed(error.localizedDescription)
            return false
        }
        if recording.captureState == .ready {
            didSaveRecording = true
            return true
        } else {
            finishAfterErrorDismissal = true
            error = .audioError(NSLocalizedString(
                "recorder.partial_saved",
                comment: "A partial recording was preserved after a capture failure"
            ))
            return false
        }
    }

    @discardableResult
    private func discardShortRecording(_ recording: Recording) -> Bool {
        AudioFileStore.delete(fileName: recording.fileName)
        modelContext.delete(recording)
        do {
            try lifecycleSaver.save(modelContext)
            activeRecording = nil
            didSaveRecording = true
            return true
        } catch {
            self.error = .persistenceFailed(error.localizedDescription)
            return false
        }
    }

    private func recoverFailedStart(_ recording: Recording) {
        guard recording.captureState == .preparing || recording.captureState == .recording else { return }
        if AudioFileStore.byteSize(fileName: recording.fileName) == 0 {
            AudioFileStore.delete(fileName: recording.fileName)
            modelContext.delete(recording)
            do {
                try lifecycleSaver.save(modelContext)
                activeRecording = nil
            } catch {
                self.error = .persistenceFailed(error.localizedDescription)
            }
            return
        }
        finalizeCapture(recording, result: nil, forcedReason: .interruptedBeforeStart)
    }

    private func finishExternalRecordingState() {
        lockScreenController.end()
        RecordingCommandRouter.shared.unregister()
        PhoneSessionController.shared.notifyEnded()
    }

    func dismissError() {
        error = nil
        guard finishAfterErrorDismissal else { return }
        finishAfterErrorDismissal = false
        didSaveRecording = true
    }

    func cancel() {
        cancellationRequested = true
        stopLiveTranscription()
        recorder.cancel()
        if let recording = activeRecording {
            modelContext.delete(recording)
            do {
                try lifecycleSaver.save(modelContext)
                activeRecording = nil
            } catch {
                self.error = .persistenceFailed(error.localizedDescription)
            }
        }
        finishExternalRecordingState()
    }

    /// Last-resort teardown, called when the hosting view disappears. If the
    /// view hierarchy is torn down while a recording is still running (nothing
    /// in SwiftUI guarantees the recorder sheet survives every ancestor swap),
    /// deallocation without this would orphan the audio file unfinalized and
    /// leave the Live Activity stuck. Stopping-and-saving here turns any
    /// unexpected teardown into a saved recording; it's a no-op after a normal
    /// stop or cancel.
    func finalizeIfAbandoned() {
        guard !didSaveRecording, recorder.state != .idle else { return }
        AppLog.recorderUI.atError.error("finalizeIfAbandoned: view torn down mid-recording, stopping and saving")
        stopAndSave()
    }
}

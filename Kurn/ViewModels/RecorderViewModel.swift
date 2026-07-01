//
//  RecorderViewModel.swift
//  Kurn
//
//  Drives RecorderView: owns the AudioRecorderService, surfaces permission and
//  error state, and persists a finished segment as a `Recording` in SwiftData.
//

import Foundation
import Observation
import os
import SwiftData

/// Recording-preference bundle for `RecorderViewModel.init`, grouping
/// settings-derived options so the initializer doesn't accumulate a
/// parameter per preference.
struct RecorderOptions {
    var micPickup: MicPickup = .wholeRoom
    var audioQuality: AudioQuality = .high
    var liveTranscriptionEnabled: Bool = false
    var hideLiveActivityMeetingTitle: Bool = true
}

@MainActor
@Observable
final class RecorderViewModel {
    let recorder = AudioRecorderService()
    let liveTranscription = LiveTranscriptionService()

    var error: AppError?
    var permissionDenied = false
    /// Set once a recording has been saved so the view can dismiss.
    var didSaveRecording = false

    private let meeting: Meeting
    private let modelContext: ModelContext
    private let defaultMode: TranscriptionMode
    private let liveTranscriptionEnabled: Bool
    private let hideLiveActivityMeetingTitle: Bool
    private let lockScreenController = LockScreenRecordingController()

    init(
        meeting: Meeting,
        modelContext: ModelContext,
        defaultMode: TranscriptionMode,
        options: RecorderOptions = RecorderOptions()
    ) {
        self.meeting = meeting
        self.modelContext = modelContext
        self.defaultMode = defaultMode
        self.liveTranscriptionEnabled = options.liveTranscriptionEnabled
        self.hideLiveActivityMeetingTitle = options.hideLiveActivityMeetingTitle
        self.recorder.micPickup = options.micPickup
        self.recorder.audioBitRate = options.audioQuality.bitRate
        self.recorder.onStateChanged = { [weak self] state, elapsed in
            self?.lockScreenController.update(state: state, elapsed: elapsed)
            self?.pushWatchState(state: state, elapsed: elapsed)
        }
        self.recorder.onLevelChanged = { level in
            PhoneSessionController.shared.pushLevel(level)
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
            isAvailable: state != .idle
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
    var routeMessage: String? { recorder.routeChangeMessage }

    /// Editable meeting title, surfaced as the recorder's "Add title…" field.
    var meetingTitle: String {
        get { meeting.title }
        set { meeting.title = newValue }
    }

    /// Request permission (if needed) and begin recording.
    func startRecording() async {
        AppLog.recorderUI.atNotice.notice("startRecording: begin, requesting permission")
        let granted = await recorder.requestMicrophonePermission()
        guard granted else {
            AppLog.recorderUI.atError.error("startRecording: permission denied")
            permissionDenied = true
            return
        }
        // Load the streaming ASR model in parallel with the audio engine
        // spin-up so the first usable buffer arrives at an already-loaded
        // engine instead of being dropped while we wait on model I/O.
        let liveLanguage = meeting.language
        let liveStartTask: Task<Void, Never>? = liveTranscriptionEnabled
            ? Task { @MainActor [weak self] in await self?.liveTranscription.start(language: liveLanguage) }
            : nil
        do {
            try await recorder.start(meetingID: meeting.id)
            // Bring up the Live Activity / Dynamic Island the instant the
            // recorder is running, BEFORE awaiting the optional live-transcription
            // model warmup. `loadModels()` can take several seconds on first run
            // (or stall/fail), and the Lock Screen widget must never be held
            // hostage to it — otherwise it appears late or, if the load hangs,
            // never at all.
            lockScreenController.start(
                title: displayTitle,
                state: recorder.state,
                elapsed: recorder.elapsed
            )
            RecordingCommandRouter.shared.register(
                onTogglePause: { [weak self] in self?.togglePause() },
                onPause: { [weak self] in self?.recorder.pause() },
                onResume: { [weak self] in self?.recorder.resume() },
                onStop: { [weak self] in self?.stopAndSave() }
            )
            await liveStartTask?.value
            AppLog.recorderUI.atInfo.info("startRecording: done, state=\(String(describing: self.recorder.state), privacy: .public)")
        } catch let appError as AppError {
            AppLog.recorderUI.atError.error("startRecording: AppError: \(appError.errorDescription ?? "nil", privacy: .public)")
            await liveStartTask?.value
            if liveTranscriptionEnabled { await liveTranscription.stop() }
            error = appError
        } catch {
            AppLog.recorderUI.atError.error("startRecording: error: \(error.localizedDescription, privacy: .public)")
            await liveStartTask?.value
            if liveTranscriptionEnabled { await liveTranscription.stop() }
            self.error = .audioError(error.localizedDescription)
        }
    }

    func togglePause() {
        AppLog.recorderUI.atInfo.info("togglePause: state=\(String(describing: self.recorder.state), privacy: .public)")
        switch recorder.state {
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        case .idle: break
        }
    }

    /// Stop, save the segment to SwiftData, and flag completion.
    func stopAndSave() {
        AppLog.recorderUI.atNotice.notice("stopAndSave: called state=\(String(describing: self.recorder.state), privacy: .public)")
        if liveTranscriptionEnabled { Task { await liveTranscription.stop() } }
        guard let result = recorder.stop() else {
            lockScreenController.end()
            RecordingCommandRouter.shared.unregister()
            PhoneSessionController.shared.notifyEnded()
            didSaveRecording = true
            return
        }
        // Ignore zero-length recordings.
        guard result.duration >= 0.5 else {
            AudioFileStore.delete(fileName: result.fileName)
            lockScreenController.end()
            RecordingCommandRouter.shared.unregister()
            PhoneSessionController.shared.notifyEnded()
            didSaveRecording = true
            return
        }

        // Setting `meeting` establishes the relationship; SwiftData maintains the
        // inverse `meeting.recordings`, so we don't append manually.
        let recording = Recording(
            meeting: meeting,
            fileName: result.fileName,
            duration: result.duration,
            transcriptionMode: defaultMode
        )
        modelContext.insert(recording)
        do {
            try modelContext.save()
        } catch {
            self.error = .persistenceFailed(error.localizedDescription)
        }
        lockScreenController.end()
        RecordingCommandRouter.shared.unregister()
        PhoneSessionController.shared.notifyEnded()
        didSaveRecording = true
    }

    func cancel() {
        if liveTranscriptionEnabled { Task { await liveTranscription.stop() } }
        recorder.cancel()
        lockScreenController.end()
        RecordingCommandRouter.shared.unregister()
        PhoneSessionController.shared.notifyEnded()
    }
}

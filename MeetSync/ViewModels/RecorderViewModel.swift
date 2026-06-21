//
//  RecorderViewModel.swift
//  MeetSync
//
//  Drives RecorderView: owns the AudioRecorderService, surfaces permission and
//  error state, and persists a finished segment as a `Recording` in SwiftData.
//

import Foundation
import Observation
import os
import SwiftData

@MainActor
@Observable
final class RecorderViewModel {
    let recorder = AudioRecorderService()

    var error: AppError?
    var permissionDenied = false
    /// Set once a recording has been saved so the view can dismiss.
    var didSaveRecording = false

    private let meeting: Meeting
    private let modelContext: ModelContext
    private let defaultMode: TranscriptionMode
    private let lockScreenController = LockScreenRecordingController()

    init(
        meeting: Meeting,
        modelContext: ModelContext,
        defaultMode: TranscriptionMode,
        micPickup: MicPickup = .wholeRoom
    ) {
        self.meeting = meeting
        self.modelContext = modelContext
        self.defaultMode = defaultMode
        self.recorder.micPickup = micPickup
        self.recorder.onStateChanged = { [weak self] state, elapsed in
            self?.lockScreenController.update(state: state, elapsed: elapsed)
            self?.pushWatchState(state: state, elapsed: elapsed)
        }
        self.recorder.onLevelChanged = { level in
            PhoneSessionController.shared.pushLevel(level)
        }
    }

    private func pushWatchState(state: AudioRecorderService.State, elapsed: TimeInterval) {
        PhoneSessionController.shared.pushState(
            state: state,
            meetingTitle: meeting.title,
            accumulatedElapsed: elapsed,
            referenceDate: Date(),
            isAvailable: state != .idle
        )
    }

    var state: AudioRecorderService.State { recorder.state }
    var level: Float { recorder.level }
    var elapsed: TimeInterval { recorder.elapsed }
    var routeMessage: String? { recorder.routeChangeMessage }

    /// Request permission (if needed) and begin recording.
    func startRecording() async {
        AppLog.recorderUI.log("startRecording: begin, requesting permission")
        let granted = await recorder.requestMicrophonePermission()
        guard granted else {
            AppLog.recorderUI.error("startRecording: permission denied")
            permissionDenied = true
            return
        }
        do {
            try await recorder.start(meetingID: meeting.id)
            lockScreenController.start(
                title: meeting.title,
                state: recorder.state,
                elapsed: recorder.elapsed
            )
            RecordingCommandRouter.shared.register(
                onTogglePause: { [weak self] in self?.togglePause() },
                onPause: { [weak self] in self?.recorder.pause() },
                onResume: { [weak self] in self?.recorder.resume() },
                onStop: { [weak self] in self?.stopAndSave() }
            )
            AppLog.recorderUI.log("startRecording: done, state=\(String(describing: self.recorder.state), privacy: .public)")
        } catch let appError as AppError {
            AppLog.recorderUI.error("startRecording: AppError: \(appError.errorDescription ?? "nil", privacy: .public)")
            error = appError
        } catch {
            AppLog.recorderUI.error("startRecording: error: \(error.localizedDescription, privacy: .public)")
            self.error = .audioError(error.localizedDescription)
        }
    }

    func togglePause() {
        AppLog.recorderUI.log("togglePause: state=\(String(describing: self.recorder.state), privacy: .public)")
        switch recorder.state {
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        case .idle: break
        }
    }

    /// Stop, save the segment to SwiftData, and flag completion.
    func stopAndSave() {
        AppLog.recorderUI.log("stopAndSave: called state=\(String(describing: self.recorder.state), privacy: .public)")
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
        recorder.cancel()
        lockScreenController.end()
        RecordingCommandRouter.shared.unregister()
        PhoneSessionController.shared.notifyEnded()
    }
}

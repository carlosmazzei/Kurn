//
//  RecorderViewModel.swift
//  MeetSync
//
//  Drives RecorderView: owns the AudioRecorderService, surfaces permission and
//  error state, and persists a finished segment as a `Recording` in SwiftData.
//

import Foundation
import Observation
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

    init(meeting: Meeting, modelContext: ModelContext) {
        self.meeting = meeting
        self.modelContext = modelContext
    }

    var state: AudioRecorderService.State { recorder.state }
    var level: Float { recorder.level }
    var elapsed: TimeInterval { recorder.elapsed }
    var routeMessage: String? { recorder.routeChangeMessage }

    /// Request permission (if needed) and begin recording.
    func startRecording() async {
        let granted = await recorder.requestMicrophonePermission()
        guard granted else {
            permissionDenied = true
            return
        }
        do {
            try recorder.start(meetingID: meeting.id)
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .audioError(error.localizedDescription)
        }
    }

    func togglePause() {
        switch recorder.state {
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        case .idle: break
        }
    }

    /// Stop, save the segment to SwiftData, and flag completion.
    func stopAndSave(defaultMode: TranscriptionMode) {
        guard let result = recorder.stop() else {
            didSaveRecording = true
            return
        }
        // Ignore zero-length recordings.
        guard result.duration >= 0.5 else {
            AudioFileStore.delete(fileName: result.fileName)
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
        try? modelContext.save()
        didSaveRecording = true
    }

    func cancel() {
        recorder.cancel()
    }
}

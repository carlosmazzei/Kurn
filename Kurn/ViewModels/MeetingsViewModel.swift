//
//  MeetingsViewModel.swift
//  Kurn
//
//  Create/delete operations for meetings. The list itself is rendered straight
//  from a SwiftData @Query in the view; this type centralizes the mutations that
//  also need to clean up on-disk audio.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class MeetingsViewModel {
    private let modelContext: ModelContext
    /// Set when a persistence operation fails, so the hosting view can surface it
    /// via `.errorAlert` instead of the failure being dropped silently.
    var error: AppError?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Insert and return a new meeting so the caller can navigate into it.
    @discardableResult
    func createMeeting(
        title: String,
        notes: String = "",
        language: MeetingLanguage = .autoDetect
    ) -> Meeting {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty
            ? String(format: NSLocalizedString("meeting.default_title", comment: "Default title"),
                     Date().isoDay)
            : trimmed
        let meeting = Meeting(title: finalTitle, notes: notes, language: language)
        modelContext.insert(meeting)
        if let failure = modelContext.saveOrError() { error = failure }
        return meeting
    }

    /// Delete a meeting and remove all of its audio files from disk.
    func delete(_ meeting: Meeting) {
        for recording in meeting.recordings {
            AudioFileStore.delete(fileName: recording.fileName)
        }
        modelContext.delete(meeting)
        if let failure = modelContext.saveOrError() { error = failure }
    }

    /// Delete a single recording segment: remove its audio file from disk, then
    /// the model. Keeping this here (rather than in the view) makes the
    /// file-cleanup behavior unit-testable.
    func deleteRecording(_ recording: Recording) {
        AudioFileStore.delete(fileName: recording.fileName)
        modelContext.delete(recording)
        if let failure = modelContext.saveOrError() { error = failure }
    }
}

//
//  MeetingsViewModel.swift
//  Kurn
//
//  Create/delete operations for meetings. The list itself is rendered straight
//  from a SwiftData @Query in the view; this type centralizes the mutations that
//  also need to clean up on-disk audio.
//

import Foundation
import KurnCore
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
    ///
    /// Runs as a journaled trash → model commit → purge operation: intent is
    /// durable before any file moves, a `save()` failure restores the files
    /// immediately, and a process death at any boundary is replayed or rolled
    /// back from the journal record on the next launch. See
    /// `RecordingOperationJournal`'s header comment.
    func delete(_ meeting: Meeting) {
        let fileNames = meeting.recordings.map(\.fileName)
        if let failure = RecordingOperationJournal.performDelete(fileNames: fileNames, commit: {
            modelContext.delete(meeting)
            return modelContext.saveOrError()
        }) {
            error = failure
        }
    }

    /// Delete a single recording segment through the same journaled
    /// trash → commit → purge path as `delete(_:)`. Keeping this here (rather
    /// than in the view) makes the file-cleanup behavior unit-testable.
    func deleteRecording(_ recording: Recording) {
        if let failure = RecordingOperationJournal.performDelete(fileNames: [recording.fileName], commit: {
            modelContext.delete(recording)
            return modelContext.saveOrError()
        }) {
            error = failure
        }
    }
}

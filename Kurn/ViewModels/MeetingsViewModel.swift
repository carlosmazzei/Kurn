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
    /// Files move into a protected trash before the model mutation runs,
    /// rather than being deleted outright: a `save()` failure restores them
    /// immediately, and a process death between the move and the purge below
    /// leaves a trash folder `RecordingTrash.sweep(context:)` reconciles on
    /// the next launch or foreground activation. See `RecordingTrash`'s
    /// header comment for why this closes the "audio gone, row survives"
    /// window the previous delete-then-delete order left open.
    func delete(_ meeting: Meeting) {
        let operationID = UUID()
        RecordingTrash.trash(fileNames: meeting.recordings.map(\.fileName), operationID: operationID)

        modelContext.delete(meeting)
        if let failure = modelContext.saveOrError() {
            RecordingTrash.restore(operationID: operationID)
            error = failure
            return
        }
        RecordingTrash.purge(operationID: operationID)
    }

    /// Delete a single recording segment: move its audio file into a
    /// protected trash, then delete the model. Keeping this here (rather
    /// than in the view) makes the file-cleanup behavior unit-testable. See
    /// `delete(_:)`'s doc comment for why this is trash-then-purge.
    func deleteRecording(_ recording: Recording) {
        let operationID = UUID()
        RecordingTrash.trash(fileNames: [recording.fileName], operationID: operationID)

        modelContext.delete(recording)
        if let failure = modelContext.saveOrError() {
            RecordingTrash.restore(operationID: operationID)
            error = failure
            return
        }
        RecordingTrash.purge(operationID: operationID)
    }
}

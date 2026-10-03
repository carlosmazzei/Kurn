//
//  LibraryEraser.swift
//  Kurn
//
//  "Delete All Data" used to be `modelContext.delete(model: Meeting.self)`
//  plus a sweep of loose `.m4a`/`.jpg` files, run from a View. That left
//  meeting-derived content behind on the device — exactly what the dialog
//  promises is gone:
//
//  - library-wide `ChatSession`s (`meeting == nil`, so no cascade reaches
//    them) and every `GeneratedDocument` (snapshots its sources by design);
//  - `Recordings/Trash`, `Recordings/Quarantine` and `Recordings/Journal`,
//    which hold audio (and references to it) for recovery;
//  - `StoreRecovery/Backups` and `StoreRecovery/Quarantine`, which are whole
//    copies of the SwiftData store — every transcript and summary.
//
//  This is the one owner of that erase. Organization (tags, folders, smart
//  folders) is kept: it describes the library, not a meeting's content.
//  Reliability events and diagnostic reports are kept too — they carry no
//  content by construction and are what Health & Recovery reads.
//
//  Models are erased first and files only after the save commits, so a failed
//  save never leaves rows pointing at audio that is already gone.
//

import Foundation
import KurnCore
import SwiftData

@MainActor
enum LibraryEraser {

    /// Erases every meeting-derived model and then every meeting-derived file.
    /// Returns the number of files that could not be removed; throws only when
    /// the model erase failed, in which case no file was touched.
    /// `removeFiles` is the on-disk half; tests replace it so they never sweep
    /// the recordings directory other suites are using.
    @discardableResult
    static func eraseAll(
        context: ModelContext,
        removeFiles: () -> Int = { eraseFiles(appSupportDirectory: ModelStoreBootCoordinator.systemAppSupportDirectory()) }
    ) throws -> Int {
        let runID = OperationID()
        let startedAt = Date()
        ReliabilityLog.record(ReliabilityEvent(operationID: runID, operation: "library_erase", outcome: .started))
        do {
            try eraseModels(in: context)
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "library_erase", stage: "persistence",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: error.publicLogCode
            ))
            throw error
        }
        let residual = removeFiles()
        ReliabilityLog.record(ReliabilityEvent(
            operationID: runID, operation: "library_erase", stage: "files",
            outcome: residual == 0 ? .succeeded : .failed,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            code: residual == 0 ? nil : "residual_files"
        ))
        return residual
    }

    /// Deletes every content model, keeping `Tag`, `Folder` and `SmartFolder`.
    ///
    /// Meetings go first and are saved on their own, so their cascade (
    /// recordings, transcripts, speakers, summaries, chunks, wiki, chats,
    /// photos) is resolved by SwiftData before the sweep below looks for
    /// leftovers. Fetch-and-delete rather than batch `delete(model:)`, so the
    /// in-context delete rules are guaranteed to run. Safe to call again after
    /// a partial failure: every step only deletes what still exists.
    static func eraseModels(in context: ModelContext) throws {
        try deleteAll(Meeting.self, in: context)
        try context.save()

        // What no meeting cascade reaches: library-wide chats and documents,
        // plus anything orphaned by an earlier interrupted delete.
        try deleteAll(ChatSession.self, in: context)
        try deleteAll(GeneratedDocument.self, in: context)
        try deleteAll(Recording.self, in: context)
        try deleteAll(Transcript.self, in: context)
        try deleteAll(Speaker.self, in: context)
        try deleteAll(Summary.self, in: context)
        try deleteAll(SemanticChunk.self, in: context)
        try deleteAll(WikiArticle.self, in: context)
        try deleteAll(MeetingPhoto.self, in: context)
        try context.save()
    }

    /// Removes every meeting-derived file: audio (with enhanced copies),
    /// photos, and every recovery copy (`eraseRecoveryCopies`). Returns how
    /// many items are still on disk.
    nonisolated static func eraseFiles(appSupportDirectory: URL?) -> Int {
        let residual = AudioFileStore.deleteAllAudio()
            + PhotoFileStore.deleteAllPhotos()
            + eraseRecoveryCopies(appSupportDirectory: appSupportDirectory)
        if residual > 0 {
            AppLog.persistence.atError.error("Library erase left \(residual, privacy: .public) item(s) on disk")
        }
        return residual
    }

    /// Removes the recordings' trash, quarantine and journal folders and the
    /// store's backups and quarantine. Returns how many are still on disk.
    nonisolated static func eraseRecoveryCopies(
        appSupportDirectory: URL?,
        recordingsDirectory: URL = AudioFileStore.recordingsDirectoryURL,
        fileManager: FileManager = .default
    ) -> Int {
        var residual = 0
        for name in [
            RecordingProtection.trashDirectoryName,
            RecordingProtection.quarantineDirectoryName,
            RecordingProtection.journalDirectoryName
        ] {
            residual += removeIfPresent(
                recordingsDirectory.appendingPathComponent(name, isDirectory: true),
                fileManager: fileManager
            )
        }
        if let appSupportDirectory {
            residual += ModelStoreBackupManager(appSupportDirectory: appSupportDirectory, fileManager: fileManager)
                .eraseAllRecoveryCopies()
        }
        return residual
    }

    /// Removes `url` (a file or a whole directory). Returns 1 when it is still
    /// there afterwards, 0 when it is gone or never existed.
    nonisolated static func removeIfPresent(_ url: URL, fileManager: FileManager) -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        try? fileManager.removeItem(at: url)
        return fileManager.fileExists(atPath: url.path) ? 1 : 0
    }

    private static func deleteAll<Model: PersistentModel>(_ type: Model.Type, in context: ModelContext) throws {
        for object in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(object)
        }
    }
}

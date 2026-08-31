//
//  RecordingOperationJournalTests.swift
//  KurnTests
//
//  Crash-point coverage for the durable operation journal: each test writes
//  the exact on-disk state a process death leaves behind at one boundary —
//  a journal record in a given state plus files in trash or not — and
//  asserts `replay(context:)` converges it. Replaying twice must be safe.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct RecordingOperationJournalTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    private func makeAudioFile() throws -> (name: String, url: URL) {
        let directory = AudioFileStore.recordingsDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "kurn-journal-test-\(UUID().uuidString).m4a"
        let url = directory.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return (name, url)
    }

    /// Simulate a death at a given boundary by writing the journal record
    /// directly, exactly as `performDelete` would have left it.
    private func writeRecord(
        id: UUID,
        kind: RecordingOperationJournal.Kind,
        fileNames: [String],
        state: RecordingOperationJournal.State
    ) throws {
        let parent = try AudioFileStore.ensureRecordingsDirectory()
        let directory = try RecordingProtection.ensureProtectedDirectory(
            named: RecordingProtection.journalDirectoryName,
            in: parent
        )
        let record = RecordingOperationJournal.Record(
            id: id, kind: kind, fileNames: fileNames, startedAt: Date(), state: state
        )
        try JSONEncoder().encode(record)
            .write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    private func hasRecord(_ id: UUID) -> Bool {
        RecordingOperationJournal.pendingRecords().contains { $0.id == id }
    }

    // MARK: - performDelete

    @Test func performDeleteTrashesCommitsAndPurges() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Standup", language: .english)
        context.insert(meeting)
        let file = try makeAudioFile()
        let recording = Recording(meeting: meeting, fileName: file.name, duration: 10)
        context.insert(recording)
        try context.save()

        let failure = RecordingOperationJournal.performDelete(fileNames: [file.name]) {
            context.delete(recording)
            return context.saveOrError()
        }

        #expect(failure == nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(RecordingOperationJournal.pendingRecords().isEmpty)
    }

    @Test func performDeleteRestoresFilesWhenCommitFails() throws {
        let file = try makeAudioFile()
        defer { AudioFileStore.delete(fileName: file.name) }

        let failure = RecordingOperationJournal.performDelete(fileNames: [file.name]) {
            .persistenceFailed("injected")
        }

        #expect(failure != nil)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(RecordingOperationJournal.pendingRecords().isEmpty)
    }

    // MARK: - replay: delete crash points

    @Test func replayRollsBackIntentStateOperation() throws {
        // Death between the intent write and the model commit: the commit
        // provably never ran, so the files must come back.
        let context = makeContext()
        let file = try makeAudioFile()
        defer { AudioFileStore.delete(fileName: file.name) }
        let operationID = UUID()
        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        try writeRecord(id: operationID, kind: .delete, fileNames: [file.name], state: .intent)

        RecordingOperationJournal.replay(context: context)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(!hasRecord(operationID))
    }

    @Test func replayRestoresInDoubtOperationWhoseRowSurvived() throws {
        // Death in the in-doubt window (after the trash move, state advanced
        // to .trashed, but the save never committed): the surviving row is
        // the authority, so the files must come back.
        let context = makeContext()
        let meeting = Meeting(title: "Standup", language: .english)
        context.insert(meeting)
        let file = try makeAudioFile()
        defer { AudioFileStore.delete(fileName: file.name) }
        let recording = Recording(meeting: meeting, fileName: file.name, duration: 10)
        context.insert(recording)
        try context.save()

        let operationID = UUID()
        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        try writeRecord(id: operationID, kind: .delete, fileNames: [file.name], state: .trashed)

        RecordingOperationJournal.replay(context: context)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(!hasRecord(operationID))
    }

    @Test func replayPurgesInDoubtOperationWhoseRowIsGone() throws {
        // Same in-doubt window, but the save did commit before the death:
        // no row references the file, so the trashed copy is discarded.
        let context = makeContext()
        let file = try makeAudioFile()
        let operationID = UUID()
        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        try writeRecord(id: operationID, kind: .delete, fileNames: [file.name], state: .trashed)

        RecordingOperationJournal.replay(context: context)

        RecordingTrash.restore(operationID: operationID)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(!hasRecord(operationID))
    }

    @Test func replayPurgesCommittedOperation() throws {
        // Death between the .committed marker and the purge: only the purge
        // remains, replayed forward without consulting the store.
        let context = makeContext()
        let file = try makeAudioFile()
        let operationID = UUID()
        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        try writeRecord(id: operationID, kind: .delete, fileNames: [file.name], state: .committed)

        RecordingOperationJournal.replay(context: context)

        RecordingTrash.restore(operationID: operationID)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(!hasRecord(operationID))
    }

    @Test func replayingTwiceIsSafe() throws {
        let context = makeContext()
        let file = try makeAudioFile()
        defer { AudioFileStore.delete(fileName: file.name) }
        let operationID = UUID()
        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        try writeRecord(id: operationID, kind: .delete, fileNames: [file.name], state: .intent)

        RecordingOperationJournal.replay(context: context)
        RecordingOperationJournal.replay(context: context)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(RecordingOperationJournal.pendingRecords().isEmpty)
    }

    // MARK: - replay: replace crash point

    @Test func replayClearsUnfinishedReplaceAndKeepsTheFile() throws {
        // Death after `replaceItemAt` but before the record was removed: the
        // swap itself is atomic, so the file must be untouched and readable.
        let context = makeContext()
        let file = try makeAudioFile()
        defer { AudioFileStore.delete(fileName: file.name) }
        let operationID = UUID()
        try writeRecord(id: operationID, kind: .replace, fileNames: [file.name], state: .intent)

        RecordingOperationJournal.replay(context: context)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(!hasRecord(operationID))
    }

    // MARK: - begin/finish replace

    @Test func beginAndFinishReplaceLeaveNoRecordBehind() throws {
        let operationID = RecordingOperationJournal.beginReplace(fileName: "any.m4a")
        let id = try #require(operationID)
        #expect(hasRecord(id))

        RecordingOperationJournal.finishReplace(operationID)
        #expect(!hasRecord(id))
    }

    // MARK: - unjournaled fallback

    @Test func performDeleteStillWorksWhenJournalCannotBeWritten() throws {
        // With the journal directory replaced by a plain file, the intent
        // write fails; the delete must degrade to journal-less
        // trash-then-purge instead of blocking the user action.
        let fm = FileManager.default
        let journalURL = RecordingOperationJournal.journalDirectoryURL
        try? fm.removeItem(at: journalURL)
        try Data([0x01]).write(to: journalURL)
        defer { try? fm.removeItem(at: journalURL) }

        let file = try makeAudioFile()

        let failure = RecordingOperationJournal.performDelete(fileNames: [file.name]) { nil }

        #expect(failure == nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    // MARK: - delete-all residual reporting

    @Test func deleteAllAudioReportsFilesItCouldNotRemove() throws {
        let file = try makeAudioFile()
        defer { AudioFileStore.delete(fileName: file.name) }

        let residual = AudioFileStore.deleteAllAudio(fileManager: RemoveRefusingFileManager())

        #expect(residual >= 1)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func deleteAllAudioReportsZeroResidualsOnACleanWipe() throws {
        _ = try makeAudioFile()

        let residual = AudioFileStore.deleteAllAudio()

        #expect(residual == 0)
    }
}

/// Deterministic fault injection: refuses every `removeItem`, simulating a
/// file the filesystem will not let go of during "Delete All Data".
private final class RemoveRefusingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

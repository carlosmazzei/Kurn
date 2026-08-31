//
//  RecordingTrashTests.swift
//  KurnTests
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct RecordingTrashTests {

    private func makeAudioFile(in directory: URL) throws -> (name: String, url: URL) {
        let name = "kurn-trash-test-\(UUID().uuidString).m4a"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return (name, url)
    }

    // MARK: - trash / purge

    @Test func trashOfMissingFilesIsANoOp() {
        let moved = RecordingTrash.trash(fileNames: ["does-not-exist-\(UUID().uuidString).m4a"], operationID: UUID())
        #expect(moved == false)
    }

    @Test func trashMovesTheFileOutOfItsOriginalLocation() throws {
        let file = try makeAudioFile(in: AudioFileStore.recordingsDirectoryURL)
        let operationID = UUID()
        defer { RecordingTrash.purge(operationID: operationID) }

        let moved = RecordingTrash.trash(fileNames: [file.name], operationID: operationID)

        #expect(moved)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func purgeAfterTrashPermanentlyRemovesTheFile() throws {
        let file = try makeAudioFile(in: AudioFileStore.recordingsDirectoryURL)
        let operationID = UUID()

        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        RecordingTrash.purge(operationID: operationID)

        // Not at the original location, and not recoverable via restore either.
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        RecordingTrash.restore(operationID: operationID)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func trashPreservesFileContentsForRestore() throws {
        let name = "kurn-trash-test-\(UUID().uuidString).m4a"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(name)
        let payload = Data(repeating: 0x7A, count: 128)
        try payload.write(to: url)
        let operationID = UUID()
        defer { AudioFileStore.delete(fileName: name) }

        RecordingTrash.trash(fileNames: [name], operationID: operationID)
        RecordingTrash.restore(operationID: operationID)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == payload)
    }

    // MARK: - restore

    @Test func restorePutsTheFileBackAtItsOriginalLocation() throws {
        let file = try makeAudioFile(in: AudioFileStore.recordingsDirectoryURL)
        let operationID = UUID()
        defer { AudioFileStore.delete(fileName: file.name) }

        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        RecordingTrash.restore(operationID: operationID)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func restoreOfAnUntrashedOperationIDIsANoOp() {
        // Must never throw or crash when called for an operation that never
        // trashed anything (e.g. a delete whose model mutation had nothing
        // on disk to begin with).
        RecordingTrash.restore(operationID: UUID())
    }

    @Test func restoreAlsoRecoversTheEnhancedCopy() throws {
        let file = try makeAudioFile(in: AudioFileStore.recordingsDirectoryURL)
        try AudioFileStore.ensureEnhancedDirectory()
        let enhancedURL = AudioFileStore.enhancedURL(fileName: file.name)
        try Data([0x09]).write(to: enhancedURL)
        let operationID = UUID()
        defer {
            AudioFileStore.delete(fileName: file.name)
        }

        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        #expect(!AudioFileStore.hasEnhancedAudio(fileName: file.name))

        RecordingTrash.restore(operationID: operationID)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(AudioFileStore.hasEnhancedAudio(fileName: file.name))
    }

    // MARK: - sweep

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func sweepRestoresFilesWhoseRecordingRowStillExists() throws {
        // Simulates a process death between the trash move and the save that
        // would have deleted this row: the row is still there, so the
        // mutation never committed and the files must come back.
        let context = makeContext()
        let meeting = Meeting(title: "Standup", language: .english)
        context.insert(meeting)
        let file = try makeAudioFile(in: AudioFileStore.recordingsDirectoryURL)
        defer { AudioFileStore.delete(fileName: file.name) }
        let recording = Recording(meeting: meeting, fileName: file.name, duration: 10)
        context.insert(recording)
        try context.save()

        let operationID = UUID()
        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))

        RecordingTrash.sweep(context: context)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func sweepPurgesFilesWhoseRecordingRowIsGone() throws {
        // Simulates a process death between the save that deleted the row
        // and the purge that follows it: the row is gone, so the mutation
        // committed and the trashed copy is safe to discard for good.
        let context = makeContext()
        let file = try makeAudioFile(in: AudioFileStore.recordingsDirectoryURL)
        let operationID = UUID()
        RecordingTrash.trash(fileNames: [file.name], operationID: operationID)

        RecordingTrash.sweep(context: context)

        RecordingTrash.restore(operationID: operationID)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func sweepWithNoTrashFoldersDoesNotThrowOrCrash() {
        let context = makeContext()
        RecordingTrash.sweep(context: context)
    }
}

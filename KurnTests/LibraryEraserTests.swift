//
//  LibraryEraserTests.swift
//  KurnTests
//
//  "Delete All Data" must leave no meeting-derived content behind — not the
//  library-wide chats and generated documents no meeting cascade reaches, and
//  not the recovery copies (trash, quarantine, journal, store backups) that
//  hold audio or whole copies of the store — while keeping tags, folders and
//  smart folders.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct LibraryEraserTests {

    // MARK: - Models

    @Test func eraseModelsRemovesEveryContentModelAndKeepsOrganization() throws {
        let container = TestModelContainer.make()
        let context = ModelContext(container)
        seedLibrary(in: context)
        try context.save()

        try LibraryEraser.eraseModels(in: context)

        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Speaker>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Summary>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SemanticChunk>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WikiArticle>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<MeetingPhoto>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<GeneratedDocument>()) == 0)

        #expect(try context.fetchCount(FetchDescriptor<Tag>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Folder>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SmartFolder>()) == 1)
    }

    @Test func eraseModelsIsSafeToRepeat() throws {
        let container = TestModelContainer.make()
        let context = ModelContext(container)
        seedLibrary(in: context)
        try context.save()

        try LibraryEraser.eraseModels(in: context)
        try LibraryEraser.eraseModels(in: context)

        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Tag>()) == 1)
    }

    // MARK: - Recovery copies

    @Test func eraseRecoveryCopiesRemovesEveryRecoveryLocation() throws {
        try withTempDirectories { appSupport, recordings in
            let recoveryItems = try seedRecoveryCopies(appSupport: appSupport, recordings: recordings)

            let residual = LibraryEraser.eraseRecoveryCopies(
                appSupportDirectory: appSupport, recordingsDirectory: recordings
            )

            #expect(residual == 0)
            for url in recoveryItems {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    @Test func eraseRecoveryCopiesReportsItemsItCouldNotRemove() throws {
        try withTempDirectories { appSupport, recordings in
            let recoveryItems = try seedRecoveryCopies(appSupport: appSupport, recordings: recordings)

            let residual = LibraryEraser.eraseRecoveryCopies(
                appSupportDirectory: appSupport,
                recordingsDirectory: recordings,
                fileManager: EraseRefusingFileManager()
            )

            #expect(residual == recoveryItems.count)
            for url in recoveryItems {
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    @Test func eraseRecoveryCopiesWithoutAppSupportStillClearsRecordingsRecovery() throws {
        try withTempDirectories { _, recordings in
            let trash = recordings.appendingPathComponent(RecordingProtection.trashDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

            let residual = LibraryEraser.eraseRecoveryCopies(appSupportDirectory: nil, recordingsDirectory: recordings)

            #expect(residual == 0)
            #expect(!FileManager.default.fileExists(atPath: trash.path))
        }
    }

    // MARK: - Helpers

    private func seedLibrary(in context: ModelContext) {
        let folder = Folder(name: "Clients")
        let tag = Tag(name: "Weekly")
        context.insert(folder)
        context.insert(tag)
        context.insert(SmartFolder(name: "Recent"))

        let meeting = Meeting(title: "Performance review", folder: folder)
        context.insert(meeting)
        meeting.tags.append(tag)

        let recording = Recording(meeting: meeting, fileName: "\(UUID().uuidString).m4a", duration: 60)
        context.insert(recording)
        context.insert(Transcript(recording: recording))
        context.insert(MeetingPhoto(recording: recording, fileName: "\(UUID().uuidString).jpg", capturedAt: 5))
        context.insert(Speaker(meeting: meeting, label: "Speaker 1", color: "#FF0000"))
        context.insert(Summary(meeting: meeting, provider: .openAI))
        context.insert(SemanticChunk(
            meeting: meeting, recordingID: recording.id, text: "Salary discussion",
            startTime: 0, endTime: 5, speakerLabel: "Speaker 1", vector: [0.1, 0.2], modelIdentifier: "test"
        ))
        context.insert(WikiArticle(
            meeting: meeting, bodyMarkdown: "Notes", meetingTitleSnapshot: meeting.title,
            meetingDate: meeting.createdAt, sourceContentHash: "hash", generatorModelIdentifier: "test"
        ))
        context.insert(ChatSession(meeting: meeting, title: "Meeting chat"))

        // Neither of these is reached by a meeting's cascade.
        context.insert(ChatSession(meeting: nil, title: "Library chat"))
        context.insert(GeneratedDocument(
            title: "Review summary", bodyMarkdown: "Derived text", userPrompt: "Summarize",
            sourceKind: .transcripts, sourceNames: [meeting.title], sourceMeetingIDs: [meeting.id],
            generatorModelIdentifier: "test"
        ))
    }

    private func withTempDirectories(_ body: (_ appSupport: URL, _ recordings: URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryEraserTests-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(appSupport, recordings)
    }

    /// Creates one file inside every recovery location and returns the
    /// top-level directories the erase is expected to remove.
    private func seedRecoveryCopies(appSupport: URL, recordings: URL) throws -> [URL] {
        let storeRecovery = appSupport.appendingPathComponent("StoreRecovery", isDirectory: true)
        let directories = [
            recordings.appendingPathComponent(RecordingProtection.trashDirectoryName, isDirectory: true),
            recordings.appendingPathComponent(RecordingProtection.quarantineDirectoryName, isDirectory: true),
            recordings.appendingPathComponent(RecordingProtection.journalDirectoryName, isDirectory: true),
            storeRecovery.appendingPathComponent("Backups", isDirectory: true),
            storeRecovery.appendingPathComponent("Quarantine", isDirectory: true)
        ]
        for directory in directories {
            let item = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            try Data("content".utf8).write(to: item.appendingPathComponent("payload"))
        }
        return directories
    }
}

/// Refuses every `removeItem`, simulating items the filesystem will not let go
/// of during the erase.
private final class EraseRefusingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

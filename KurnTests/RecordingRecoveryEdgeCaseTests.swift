//
//  RecordingRecoveryEdgeCaseTests.swift
//  KurnTests
//
//  Complements RecordingRecoveryTests with the discard/keep edge paths:
//  filenames the `{meetingID}_{timestamp}.m4a` parser can't resolve and
//  recordings too short or too small to matter are deleted; large unreadable
//  orphans (a long recording whose container was never finalized) are kept on
//  disk; and the foreground-activation sweep reattaches orphans but never
//  while a recorder session is live.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct RecordingRecoveryEdgeCaseTests {

    @Test func fileWithoutUnderscoreIsDeleted() throws {
        let container = TestModelContainer.make()
        let fileName = "nounderscore.m4a"
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
    }

    @Test func fileWithMalformedUUIDIsDeleted() throws {
        let container = TestModelContainer.make()
        let fileName = "not-a-uuid_20250101-000000.m4a"
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
    }

    @Test func largeUnreadableOrphanIsKeptOnDisk() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Long meeting")
        context.insert(meeting)
        try context.save()

        // Not a valid audio container — like an .m4a abandoned before its
        // writer could finalize it — but big enough to plausibly be a long
        // recording. It must be preserved, not deleted.
        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try Data(repeating: 0xAB, count: RecordingRecovery.keepUnreadableMinBytes).write(to: url)
        let migrated = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: migrated)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        // Not reattached (unreadable), but the bytes survive on disk.
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        let stillOnDisk = FileManager.default.fileExists(atPath: migrated.path)
            || FileManager.default.fileExists(atPath: url.path)
        #expect(stillOnDisk)
    }

    @Test func smallUnreadableOrphanIsDeleted() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Blip")
        context.insert(meeting)
        try context.save()

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try Data(repeating: 0xAB, count: 10_000).write(to: url)
        let migrated = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: migrated)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: migrated.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func activateRecoveryReattachesOrphanUnlessRecordingIsLive() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Meeting")
        context.insert(meeting)
        try context.save()

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // While a recorder session is registered, the sweep must not touch
        // anything — the in-progress file has no Recording row yet.
        RecordingCommandRouter.shared.register(
            onTogglePause: {}, onPause: {}, onResume: {}, onStop: {}
        )
        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)

        // Once no session is live, the orphan is reattached without a relaunch.
        RecordingCommandRouter.shared.unregister()
        RecordingRecovery.recoverOrphansOnActivate(modelContainer: container)
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(recordings.first?.fileName == fileName)
    }

    @Test func tooShortRecordingIsDeletedNotReattached() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        try context.save()

        // Below the 0.5s minimum readable duration, so it isn't reattached.
        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 0.2, at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

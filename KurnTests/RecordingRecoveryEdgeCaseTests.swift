//
//  RecordingRecoveryEdgeCaseTests.swift
//  KurnTests
//
//  Complements RecordingRecoveryTests with the preserve/quarantine edge paths:
//  filenames the `{meetingID}_{timestamp}.m4a` parser can't resolve, unreadable
//  containers, and recordings too short to reattach all move to protected
//  quarantine instead of being deleted; the foreground-activation sweep
//  reattaches orphans but never while a recorder session is live.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct RecordingRecoveryEdgeCaseTests {

    /// Remove only this test's items from the shared quarantine directory, so
    /// parallel suites quarantining their own fixtures are untouched.
    private func purgeQuarantined(fileName: String) {
        for item in RecordingQuarantine.items() where item.fileName == fileName {
            RecordingQuarantine.delete(item)
        }
    }

    private func quarantined(fileName: String) -> QuarantinedRecording? {
        RecordingQuarantine.items().first { $0.fileName == fileName }
    }

    @Test func fileWithoutUnderscoreIsQuarantined() throws {
        let container = TestModelContainer.make()
        let fileName = "nounderscore-\(UUID().uuidString).m4a"
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            purgeQuarantined(fileName: fileName)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let item = try #require(quarantined(fileName: fileName))
        #expect(item.reason == .unparsableFileName)
        #expect(item.byteSize > 0)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        #expect(!recordings.contains { $0.fileName == fileName })
    }

    @Test func fileWithMalformedUUIDIsQuarantined() throws {
        let container = TestModelContainer.make()
        let fileName = "not-a-uuid_\(UUID().uuidString).m4a"
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            purgeQuarantined(fileName: fileName)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let item = try #require(quarantined(fileName: fileName))
        #expect(item.reason == .unparsableFileName)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    @Test func largeUnreadableOrphanIsQuarantined() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Long meeting")
        context.insert(meeting)
        try context.save()

        // Not a valid audio container — like an .m4a abandoned before its
        // writer could finalize it — but big enough to plausibly be a long
        // recording. Its bytes must survive.
        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try Data(repeating: 0xAB, count: 1_000_000).write(to: url)
        let migrated = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: migrated)
            purgeQuarantined(fileName: fileName)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        // Not reattached (unreadable), but the bytes survive in quarantine.
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        let item = try #require(quarantined(fileName: fileName))
        #expect(item.reason == .unreadableContainer)
        #expect(item.byteSize == 1_000_000)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    @Test func smallUnreadableOrphanIsQuarantinedNotDeleted() throws {
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
            purgeQuarantined(fileName: fileName)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        // Even a small unreadable file is the only copy of the user's audio:
        // preserved with a reason, never deleted.
        let item = try #require(quarantined(fileName: fileName))
        #expect(item.reason == .unreadableContainer)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
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
            onTogglePause: {}, onPause: {}, onResume: {}, onStop: { true }, onHighlight: {}
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

    @Test func tooShortRecordingIsQuarantinedNotReattached() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        try context.save()

        // Below the 0.5s minimum readable duration, so it isn't reattached.
        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 0.2, at: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            purgeQuarantined(fileName: fileName)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let item = try #require(quarantined(fileName: fileName))
        #expect(item.reason == .negligibleDuration)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    @Test func legacyMigrationCollisionPreservesBothCopies() throws {
        let container = TestModelContainer.make()
        let meeting = Meeting(title: "Collision")
        container.mainContext.insert(meeting)
        try container.mainContext.save()

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let protected = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: protected)
        let protectedBytes = try Data(contentsOf: protected)

        // A *different* file with the same name still in Documents.
        let legacy = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try Data(repeating: 0xCD, count: 50_000).write(to: legacy)
        defer {
            try? FileManager.default.removeItem(at: protected)
            try? FileManager.default.removeItem(at: legacy)
            purgeQuarantined(fileName: fileName)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        // The protected copy is untouched; the ambiguous legacy copy is
        // preserved in quarantine, not deleted.
        #expect(try Data(contentsOf: protected) == protectedBytes)
        let item = try #require(quarantined(fileName: fileName))
        #expect(item.reason == .legacyCollision)
        #expect(try Data(contentsOf: item.fileURL) == Data(repeating: 0xCD, count: 50_000))
    }

    @Test func legacyMigrationIdenticalCollisionDropsTheRedundantCopy() throws {
        let container = TestModelContainer.make()
        let meeting = Meeting(title: "Duplicate")
        container.mainContext.insert(meeting)
        try container.mainContext.save()

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let protected = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: protected)
        let legacy = AudioFileStore.documentsURL.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: protected, to: legacy)
        defer {
            try? FileManager.default.removeItem(at: protected)
            try? FileManager.default.removeItem(at: legacy)
            purgeQuarantined(fileName: fileName)
        }

        RecordingRecovery.recoverOrphans(modelContainer: container)

        // Byte-identical, so removing the legacy copy loses nothing.
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(quarantined(fileName: fileName) == nil)
    }
}

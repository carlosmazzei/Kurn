//
//  RecordingRecoveryEdgeCaseTests.swift
//  KurnTests
//
//  Complements RecordingRecoveryTests with the discard paths: filenames the
//  `{meetingID}_{timestamp}.m4a` parser can't resolve, and recordings too short
//  to be worth keeping. In every case the orphaned file should be deleted rather
//  than left lingering in Documents.
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

//
//  RecordingQuarantineTests.swift
//  KurnTests
//
//  The quarantine's core contract — preserve, never lose — plus the
//  fail-closed protected-storage seams: a filesystem fault while quarantining
//  leaves the original in place, a metadata fault still preserves the audio,
//  recovery puts an item back into the library, and the throwing directory
//  accessors surface a typed error instead of falling back to an unverified
//  path.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Deterministic filesystem fault injection: every directory creation and
/// every move fails, the way a full disk or a protection-attribute failure
/// would.
private final class FailingFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@MainActor
struct RecordingQuarantineTests {

    private func purgeQuarantined(fileName: String) {
        for item in RecordingQuarantine.items() where item.fileName == fileName {
            RecordingQuarantine.delete(item)
        }
    }

    @Test func quarantineMovesFileAndRecordsMetadata() throws {
        let fileName = "quarantine-\(UUID().uuidString).m4a"
        let url = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
        let payload = Data(repeating: 0x5A, count: 2_048)
        try payload.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            purgeQuarantined(fileName: fileName)
        }

        #expect(RecordingQuarantine.quarantine(fileAt: url, reason: .meetingNotFound))

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let item = try #require(RecordingQuarantine.items().first { $0.fileName == fileName })
        #expect(item.reason == .meetingNotFound)
        #expect(item.byteSize == Int64(payload.count))
        #expect(abs(item.quarantinedAt.timeIntervalSinceNow) < 60)
        #expect(try Data(contentsOf: item.fileURL) == payload)
    }

    @Test func filesystemFaultDuringQuarantineLeavesOriginalInPlace() throws {
        let fileName = "quarantine-fault-\(UUID().uuidString).m4a"
        let url = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
        let payload = Data(repeating: 0x3C, count: 1_024)
        try payload.write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            purgeQuarantined(fileName: fileName)
        }

        let moved = RecordingQuarantine.quarantine(
            fileAt: url,
            reason: .unreadableContainer,
            fileManager: FailingFileManager()
        )

        #expect(!moved)
        // The one thing that must never happen: losing the original.
        #expect(try Data(contentsOf: url) == payload)
        #expect(RecordingQuarantine.items().first { $0.fileName == fileName } == nil)
    }

    @Test func itemWithUnreadableMetadataIsStillListed() throws {
        let fileName = "quarantine-nometa-\(UUID().uuidString).m4a"
        let url = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
        try Data(repeating: 0x77, count: 512).write(to: url)
        defer { purgeQuarantined(fileName: fileName) }

        #expect(RecordingQuarantine.quarantine(fileAt: url, reason: .unparsableFileName))
        let item = try #require(RecordingQuarantine.items().first { $0.fileName == fileName })
        try FileManager.default.removeItem(
            at: RecordingQuarantine.itemDirectory(id: item.id).appendingPathComponent("metadata.json")
        )

        // The audio is what matters: missing metadata degrades the listing,
        // never hides (or drops) the file.
        let relisted = try #require(RecordingQuarantine.items().first { $0.fileName == fileName })
        #expect(relisted.reason == .unknown)
        #expect(relisted.byteSize == 512)
        #expect(FileManager.default.fileExists(atPath: relisted.fileURL.path))
    }

    @Test func recoverReattachesQuarantinedAudioToItsMeeting() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Recoverable")
        context.insert(meeting)
        try context.save()

        let fileName = AudioFileStore.fileName(meetingID: meeting.id)
        let url = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: url)
        defer {
            AudioFileStore.delete(fileName: fileName)
            purgeQuarantined(fileName: fileName)
        }
        #expect(RecordingQuarantine.quarantine(fileAt: url, reason: .meetingNotFound))
        let item = try #require(RecordingQuarantine.items().first { $0.fileName == fileName })

        let error = RecordingQuarantine.recover(item, context: context)

        #expect(error == nil)
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(recordings.first?.meeting?.id == meeting.id)
        #expect(FileManager.default.fileExists(
            atPath: AudioFileStore.resolveURL(fileName: recordings.first?.fileName ?? "").path
        ))
        #expect(RecordingQuarantine.items().first { $0.fileName == fileName } == nil)
    }

    @Test func recoverCreatesAMeetingWhenTheOriginalIsGone() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext

        let fileName = AudioFileStore.fileName(meetingID: UUID())
        let url = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1.0, at: url)
        defer {
            AudioFileStore.delete(fileName: fileName)
            purgeQuarantined(fileName: fileName)
        }
        #expect(RecordingQuarantine.quarantine(fileAt: url, reason: .meetingNotFound))
        let item = try #require(RecordingQuarantine.items().first { $0.fileName == fileName })

        let error = RecordingQuarantine.recover(item, context: context)

        #expect(error == nil)
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 1)
        #expect(recordings.first?.meeting != nil)
    }

    @Test func recoverOfUnreadableAudioReturnsItToQuarantine() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext

        let fileName = AudioFileStore.fileName(meetingID: UUID())
        let url = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
        try Data(repeating: 0xEE, count: 4_096).write(to: url)
        defer {
            AudioFileStore.delete(fileName: fileName)
            purgeQuarantined(fileName: fileName)
        }
        #expect(RecordingQuarantine.quarantine(fileAt: url, reason: .unreadableContainer))
        let item = try #require(RecordingQuarantine.items().first { $0.fileName == fileName })

        let error = RecordingQuarantine.recover(item, context: context)

        #expect(error != nil)
        // Preserve-or-recover: the failed recovery moved the bytes back.
        #expect(try Data(contentsOf: item.fileURL) == Data(repeating: 0xEE, count: 4_096))
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(recordings.isEmpty)
    }

    @Test func ensureRecordingsDirectoryFailsClosedInsteadOfFallingBack() {
        #expect(throws: AppError.self) {
            try AudioFileStore.ensureRecordingsDirectory(fileManager: FailingFileManager())
        }
        #expect(throws: AppError.self) {
            try AudioFileStore.ensureEnhancedDirectory(fileManager: FailingFileManager())
        }
    }
}

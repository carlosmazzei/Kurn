//
//  MeetingLibraryAttachmentTests.swift
//  KurnTests
//
//  `MeetingLibrary`'s attachment rules: a recorded attachment keeps its
//  measured size, deleting one removes its file through the journal, a
//  meeting's deletion takes its attachments' files with it, and a crash
//  mid-delete is reconciled by `RecordingTrash.sweep` like a photo's.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingLibraryAttachmentTests {

    private func makeLibrary() -> (MeetingLibrary, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        return (MeetingLibrary(context: context), context)
    }

    /// A stored attachment file for `meeting`, as the importer leaves it.
    private func storeFile(for meeting: Meeting) throws -> String {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data(repeating: 0x25, count: 512).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try AttachmentFileStore.importCopy(of: source, meetingID: meeting.id)
    }

    private func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: AttachmentFileStore.resolveURL(fileName: fileName).path)
    }

    @Test func addAttachmentRecordsItWithItsMeasuredSize() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Planning")
        let fileName = try storeFile(for: meeting)
        defer { AttachmentFileStore.delete(fileName: fileName) }

        let attachment = try library.addAttachment(
            to: meeting, fileName: fileName, displayName: "Plan.pdf", pageCount: 4, extractedText: "Roadmap"
        )

        #expect(attachment.fileSize == 512)
        #expect(attachment.pageCount == 4)
        #expect(meeting.sortedAttachments.map(\.displayName) == ["Plan.pdf"])
        #expect(try context.fetchCount(FetchDescriptor<MeetingAttachment>()) == 1)
    }

    @Test func deleteAttachmentRemovesItsFileAndKeepsTheMeeting() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Planning")
        let fileName = try storeFile(for: meeting)
        defer { AttachmentFileStore.delete(fileName: fileName) }
        let attachment = try library.addAttachment(
            to: meeting, fileName: fileName, displayName: "Plan.pdf", pageCount: 1, extractedText: nil
        )

        try library.deleteAttachment(attachment)

        #expect(!exists(fileName))
        #expect(try context.fetchCount(FetchDescriptor<MeetingAttachment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 1)
    }

    @Test func deleteMeetingRemovesItsAttachmentFiles() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Planning")
        let first = try storeFile(for: meeting)
        let second = try storeFile(for: meeting)
        defer { [first, second].forEach(AttachmentFileStore.delete) }
        try library.addAttachment(to: meeting, fileName: first, displayName: "A.pdf", pageCount: 1, extractedText: "A")
        try library.addAttachment(to: meeting, fileName: second, displayName: "B.pdf", pageCount: 1, extractedText: "B")

        try library.deleteMeeting(meeting)

        #expect(!exists(first))
        #expect(!exists(second))
        #expect(try context.fetchCount(FetchDescriptor<MeetingAttachment>()) == 0)
    }

    @Test func attachmentsAreSortedByWhenTheyWereAdded() throws {
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Planning")
        context.insert(MeetingAttachment(
            meeting: meeting, fileName: "b.pdf", displayName: "Second", createdAt: Date(timeIntervalSince1970: 20)
        ))
        context.insert(MeetingAttachment(
            meeting: meeting, fileName: "a.pdf", displayName: "First", createdAt: Date(timeIntervalSince1970: 10)
        ))
        try context.save()

        #expect(meeting.sortedAttachments.map(\.displayName) == ["First", "Second"])
    }

    @Test func sweepRestoresATrashedAttachmentWhoseRowStillExists() throws {
        // A process death between the trash move and the save that would
        // have deleted the row: the row is still there, so the file returns.
        let (library, context) = makeLibrary()
        let meeting = try library.createMeeting(title: "Planning")
        let fileName = try storeFile(for: meeting)
        defer { AttachmentFileStore.delete(fileName: fileName) }
        try library.addAttachment(to: meeting, fileName: fileName, displayName: "Plan.pdf", pageCount: 1, extractedText: nil)

        let operationID = UUID()
        RecordingTrash.trash(fileNames: [fileName], operationID: operationID)
        #expect(!exists(fileName))

        RecordingTrash.sweep(context: context)

        #expect(exists(fileName))
    }
}

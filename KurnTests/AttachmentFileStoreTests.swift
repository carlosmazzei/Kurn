//
//  AttachmentFileStoreTests.swift
//  KurnTests
//
//  Attached documents on disk: deterministic names, the protected
//  directory, a copy that leaves its source alone, sizes, and deletes that
//  tolerate a missing file. Every test works on files it created itself,
//  because the attachments directory is shared with the rest of the host.
//

import Foundation
import Testing
@testable import Kurn

struct AttachmentFileStoreTests {

    @Test func fileNameIsMeetingThenAttachmentID() {
        let meeting = UUID()
        let attachment = UUID()
        #expect(AttachmentFileStore.fileName(meetingID: meeting, attachmentID: attachment)
                == "\(meeting.uuidString)_\(attachment.uuidString).pdf")
        #expect(AttachmentFileStore.fileName(meetingID: meeting) != AttachmentFileStore.fileName(meetingID: meeting))
    }

    @Test func attachmentsLiveInTheProtectedRecordingsSubdirectory() throws {
        let directory = AttachmentFileStore.attachmentsDirectoryURL
        #expect(directory.lastPathComponent == RecordingProtection.attachmentsDirectoryName)
        #expect(directory.deletingLastPathComponent().standardizedFileURL.path
                == AudioFileStore.recordingsDirectoryURL.standardizedFileURL.path)
        #expect(AttachmentFileStore.resolveURL(fileName: "a.pdf") == directory.appendingPathComponent("a.pdf"))

        let ensured = try AttachmentFileStore.ensureAttachmentsDirectory()
        #expect(ensured.standardizedFileURL.path == directory.standardizedFileURL.path)
    }

    @Test func importCopyMeasureAndDeleteRoundTrip() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        let payload = Data(repeating: 0x25, count: 2_048)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let name = try AttachmentFileStore.importCopy(of: source, meetingID: UUID())
        defer { AttachmentFileStore.delete(fileName: name) }

        let url = AttachmentFileStore.resolveURL(fileName: name)
        #expect(try Data(contentsOf: url) == payload)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(AttachmentFileStore.byteSize(fileName: name) == 2_048)

        AttachmentFileStore.delete(fileName: name)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(AttachmentFileStore.byteSize(fileName: name) == 0)
    }

    @Test func importCopyOfAMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        #expect(throws: (any Error).self) {
            try AttachmentFileStore.importCopy(of: missing, meetingID: UUID())
        }
    }

    @Test func aDirectoryThatCannotBeProtectedIsReportedAsProtectedStorage() {
        let fileManager = AttachmentsDirectoryRefusingFileManager()
        do {
            try AttachmentFileStore.ensureAttachmentsDirectory(fileManager: fileManager)
            Issue.record("a refused directory must throw")
        } catch let error as AppError {
            #expect(error.logCode == AppError.protectedStorageUnavailable("").logCode)
        } catch {
            Issue.record("expected an AppError, got \(error)")
        }
    }

    @Test func deletingAMissingAttachmentIsHarmless() {
        AttachmentFileStore.delete(fileName: "\(UUID().uuidString).pdf")
        #expect(AttachmentFileStore.byteSize(fileName: "\(UUID().uuidString).pdf") == 0)
    }

    @Test func deleteAllRemovesEveryFileInADirectory() throws {
        // A directory of its own: the shared attachments directory holds
        // other tests' files while they run in parallel.
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        for index in 0..<3 {
            try Data([UInt8(index)]).write(to: directory.appendingPathComponent("\(index).pdf"))
        }

        let residual = AttachmentFileStore.deleteAllAttachments(in: directory)

        #expect(residual == 0)
        #expect(try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(AttachmentFileStore.deleteAllAttachments(in: directory.appendingPathComponent("missing")) == 0)
    }
}

/// Deterministic fault injection: refuses to create or re-stamp the
/// attachments directory, and only that one, so the recordings directory
/// above it is still set up normally.
private final class AttachmentsDirectoryRefusingFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        guard url.lastPathComponent != RecordingProtection.attachmentsDirectoryName else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        guard (path as NSString).lastPathComponent != RecordingProtection.attachmentsDirectoryName else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

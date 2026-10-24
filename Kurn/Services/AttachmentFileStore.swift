//
//  AttachmentFileStore.swift
//  Kurn
//
//  Where the documents attached to a meeting live on disk: a protected
//  subdirectory (`Documents/Recordings/Attachments/`, with
//  `FileProtectionType.completeUnlessOpen`) beside `Photos/`, so an agenda or
//  a report attached to a meeting is encrypted at rest exactly like the
//  meeting's audio. Files are addressed by name and resolved against the
//  *current* container, mirroring `PhotoFileStore`.
//
//  `importCopy` takes the file from wherever it came from — a Files pick
//  (security-scoped) or the `Documents/Inbox` copy iOS makes when another
//  app shares a file into this one — and never moves or deletes the source;
//  the caller decides what happens to it.
//

import Foundation
import KurnCore

enum AttachmentFileStore {
    /// The protected subdirectory that holds every attachment.
    /// **Computed only — this does not create or re-stamp anything.**
    static var attachmentsDirectoryURL: URL {
        AudioFileStore.recordingsDirectoryURL
            .appendingPathComponent(RecordingProtection.attachmentsDirectoryName, isDirectory: true)
    }

    /// Same directory, created and protection-stamped, for writers.
    @discardableResult
    static func ensureAttachmentsDirectory(fileManager: FileManager = .default) throws -> URL {
        let parent = try AudioFileStore.ensureRecordingsDirectory(fileManager: fileManager)
        do {
            return try RecordingProtection.ensureProtectedDirectory(
                named: RecordingProtection.attachmentsDirectoryName,
                in: parent,
                fileManager: fileManager
            )
        } catch {
            throw AppError.protectedStorageUnavailable(error.localizedDescription)
        }
    }

    /// Deterministic file name for an attachment: `{meetingID}_{attachmentID}.pdf`.
    static func fileName(meetingID: UUID, attachmentID: UUID = UUID()) -> String {
        "\(meetingID.uuidString)_\(attachmentID.uuidString).pdf"
    }

    static func resolveURL(fileName: String) -> URL {
        attachmentsDirectoryURL.appendingPathComponent(fileName)
    }

    /// Copies the file at `source` into the protected directory under a new
    /// name and returns that name. Opens a security-scoped access window for
    /// the copy when `source` needs one (a Files pick); a plain file URL is
    /// copied as is.
    static func importCopy(of source: URL, meetingID: UUID, fileManager: FileManager = .default) throws -> String {
        let directory = try ensureAttachmentsDirectory(fileManager: fileManager)
        let name = fileName(meetingID: meetingID)
        let destination = directory.appendingPathComponent(name)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw AppError.protectedStorageUnavailable(error.localizedDescription)
        }
        RecordingProtection.apply(to: destination)
        return name
    }

    /// Delete a single attachment by name. Missing files are ignored.
    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: resolveURL(fileName: fileName))
    }

    /// Size in bytes of a stored attachment; 0 when missing.
    static func byteSize(fileName: String) -> Int64 {
        let size = (try? resolveURL(fileName: fileName).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    /// Delete every stored attachment (used by "Delete All Data"). Returns
    /// the number still on disk afterwards, mirroring
    /// `PhotoFileStore.deleteAllPhotos`.
    @discardableResult
    static func deleteAllAttachments(
        in directory: URL = attachmentsDirectoryURL,
        fileManager: FileManager = .default
    ) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }
        var residual = 0
        for url in items {
            try? fileManager.removeItem(at: url)
            if fileManager.fileExists(atPath: url.path) { residual += 1 }
        }
        return residual
    }
}

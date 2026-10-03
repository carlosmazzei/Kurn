//
//  PhotoFileStore.swift
//  Kurn
//
//  Helpers for locating and measuring on-disk meeting photos. Photos live in
//  a protected subdirectory (`Documents/Recordings/Photos/`, with
//  `FileProtectionType.completeUnlessOpen`, the same protection class and
//  parent directory `AudioFileStore` uses for audio) so a photo of a
//  whiteboard or a document is encrypted at rest exactly like the recording
//  it was taken during. Files are addressed by file name and resolved
//  against the *current* container, mirroring `AudioFileStore.resolveURL`.
//

import Foundation
import KurnCore

enum PhotoFileStore {
    /// The protected subdirectory that holds every captured photo.
    /// **Computed only — this does not create or re-stamp anything.**
    static var photosDirectoryURL: URL {
        AudioFileStore.recordingsDirectoryURL
            .appendingPathComponent(RecordingProtection.photosDirectoryName, isDirectory: true)
    }

    /// Same directory, created and protection-stamped, for writers. Throws a
    /// typed error instead of falling back to an unverified path, mirroring
    /// `AudioFileStore.ensureRecordingsDirectory`.
    @discardableResult
    static func ensurePhotosDirectory(fileManager: FileManager = .default) throws -> URL {
        let parent = try AudioFileStore.ensureRecordingsDirectory(fileManager: fileManager)
        do {
            return try RecordingProtection.ensureProtectedDirectory(
                named: RecordingProtection.photosDirectoryName,
                in: parent,
                fileManager: fileManager
            )
        } catch {
            throw AppError.protectedStorageUnavailable(error.localizedDescription)
        }
    }

    /// Deterministic file name for a photo: `{recordingID}_{photoID}.jpg`.
    static func fileName(recordingID: UUID, photoID: UUID = UUID()) -> String {
        "\(recordingID.uuidString)_\(photoID.uuidString).jpg"
    }

    /// Resolve a stored file name to its absolute URL in the protected
    /// directory. Unlike `AudioFileStore.resolveURL` there is no legacy
    /// fallback location — every photo has always lived here.
    static func resolveURL(fileName: String) -> URL {
        photosDirectoryURL.appendingPathComponent(fileName)
    }

    /// Write `data` (JPEG bytes) as a new protected photo file and return its
    /// file name. Throws if the protected directory cannot be established or
    /// the write fails.
    static func write(_ data: Data, recordingID: UUID, fileManager: FileManager = .default) throws -> String {
        let directory = try ensurePhotosDirectory(fileManager: fileManager)
        let name = fileName(recordingID: recordingID)
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            throw AppError.protectedStorageUnavailable(error.localizedDescription)
        }
        RecordingProtection.apply(to: url)
        return name
    }

    /// Delete a single photo by name. Missing files are ignored.
    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: resolveURL(fileName: fileName))
    }

    /// Size in bytes of a single stored photo. Returns 0 when missing.
    static func byteSize(fileName: String) -> Int64 {
        let url = resolveURL(fileName: fileName)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    /// Delete every stored photo (used by "Delete All Data"). Returns the
    /// number that could not be removed and are still on disk, mirroring
    /// `AudioFileStore.deleteAllAudio`.
    @discardableResult
    static func deleteAllPhotos(fileManager: FileManager = .default) -> Int {
        let fm = fileManager
        guard let items = try? fm.contentsOfDirectory(
            at: photosDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }
        var residual = 0
        for url in items where url.pathExtension.lowercased() == "jpg" {
            try? fm.removeItem(at: url)
            if fm.fileExists(atPath: url.path) { residual += 1 }
        }
        return residual
    }

    /// Total bytes used by every stored photo.
    static func totalPhotoBytes() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: photosDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }
        return items
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .reduce(into: Int64(0)) { total, url in
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }
}

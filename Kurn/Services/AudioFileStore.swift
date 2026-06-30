//
//  AudioFileStore.swift
//  Kurn
//
//  Helpers for locating and measuring on-disk audio. Recordings live in a
//  protected subdirectory (`Documents/Recordings/`, with
//  `FileProtectionType.completeUnlessOpen` so the audio is encrypted at rest
//  using a key derived from the device passcode). Files are addressed by file
//  name and resolved against the *current* container, so they keep working
//  even if the app container path changes between launches.
//

import Foundation

enum AudioFileStore {
    /// The app's Documents directory in the current container.
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The protected subdirectory that holds every `.m4a`. Creating it on
    /// access keeps every code path that produces or consumes a recording
    /// honouring the protection class without spreading the setup call.
    static var recordingsDirectoryURL: URL {
        if let url = try? RecordingProtection.ensureProtectedDirectory(at: documentsURL) {
            return url
        }
        return documentsURL.appendingPathComponent(RecordingProtection.directoryName, isDirectory: true)
    }

    /// Deterministic file name for a recording: `{meetingID}_{timestamp}.m4a`.
    static func fileName(meetingID: UUID, date: Date = Date()) -> String {
        "\(meetingID.uuidString)_\(date.fileTimestamp).m4a"
    }

    /// Resolve a stored file name to its absolute URL, preferring the
    /// protected subdirectory. Pre-migration files still in Documents are
    /// honoured as a fallback so an upgrade-in-progress launch doesn't
    /// lose access to them between the launch and the migration step.
    static func resolveURL(fileName: String) -> URL {
        let protected = recordingsDirectoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: protected.path) {
            return protected
        }
        let legacy = documentsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return protected
    }

    /// Total bytes used by every `.m4a` across both the protected directory
    /// and any pre-migration leftovers in Documents.
    static func totalAudioBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for directory in [recordingsDirectoryURL, documentsURL] {
            guard let items = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            for url in items where url.pathExtension.lowercased() == "m4a" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    /// Delete a single audio file by name from whichever directory holds it.
    /// Missing files are ignored.
    static func delete(fileName: String) {
        let fm = FileManager.default
        for directory in [recordingsDirectoryURL, documentsURL] {
            let url = directory.appendingPathComponent(fileName)
            try? fm.removeItem(at: url)
        }
    }

    /// Delete every `.m4a` from the protected directory and from Documents
    /// (used by "Delete All Data").
    static func deleteAllAudio() {
        let fm = FileManager.default
        for directory in [recordingsDirectoryURL, documentsURL] {
            guard let items = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            for url in items where url.pathExtension.lowercased() == "m4a" {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Human-readable byte count, e.g. "12.4 MB".
    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

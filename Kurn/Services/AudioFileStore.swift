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

    /// Directory holding the derived enhanced listening copies, nested inside the
    /// protected recordings directory so it inherits the same protection class.
    ///
    /// An enhanced copy keeps the *same file name* as the recording it came from —
    /// the directory is what distinguishes them. That makes the mapping an
    /// identity rather than a name-parsing exercise, and keeps the copies out of
    /// every shallow directory scan in the app. See
    /// `RecordingProtection.enhancedDirectoryName` for why that matters.
    static var enhancedDirectoryURL: URL {
        let parent = recordingsDirectoryURL
        if let url = try? RecordingProtection.ensureProtectedDirectory(
            named: RecordingProtection.enhancedDirectoryName,
            in: parent
        ) {
            return url
        }
        return parent.appendingPathComponent(
            RecordingProtection.enhancedDirectoryName,
            isDirectory: true
        )
    }

    /// Absolute URL of a recording's enhanced copy, whether or not it exists yet.
    static func enhancedURL(fileName: String) -> URL {
        enhancedDirectoryURL.appendingPathComponent(fileName)
    }

    /// Whether an enhanced copy is present on disk for this recording.
    static func hasEnhancedAudio(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: enhancedURL(fileName: fileName).path)
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

    /// Size in bytes of a single stored recording, resolved the same way
    /// `resolveURL` does. Returns 0 when the file is missing or unreadable.
    static func byteSize(fileName: String) -> Int64 {
        let url = resolveURL(fileName: fileName)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    /// Delete a single audio file by name from whichever directory holds it.
    /// Missing files are ignored.
    ///
    /// The enhanced directory is in this list so that *every* caller — deleting a
    /// meeting, deleting one recording, discarding a cancelled take — drops the
    /// derived copy along with the original, without any of them having to know
    /// the copy exists.
    static func delete(fileName: String) {
        let fm = FileManager.default
        for directory in [recordingsDirectoryURL, enhancedDirectoryURL, documentsURL] {
            let url = directory.appendingPathComponent(fileName)
            try? fm.removeItem(at: url)
        }
    }

    /// Delete only the enhanced copy, leaving the recording itself alone. Backs
    /// the "reclaim space" action in Settings → Storage.
    static func deleteEnhancedAudio(fileName: String) {
        try? FileManager.default.removeItem(at: enhancedURL(fileName: fileName))
    }

    /// Total bytes used by the derived enhanced copies. Reported separately from
    /// `totalAudioBytes()` — which counts only originals, since its scan is
    /// shallow — so Settings can show what is reclaimable without conflating it
    /// with the recordings themselves.
    static func enhancedAudioBytes() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: enhancedDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }
        return items
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .reduce(into: Int64(0)) { total, url in
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }

    /// Remove every enhanced copy. They are derived, so this only costs the time
    /// to regenerate them on the next listen.
    static func deleteAllEnhancedAudio() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: enhancedDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }
        for url in items where url.pathExtension.lowercased() == "m4a" {
            try? fm.removeItem(at: url)
        }
    }

    /// Delete every `.m4a` from the protected directory and from Documents
    /// (used by "Delete All Data").
    static func deleteAllAudio() {
        let fm = FileManager.default
        deleteAllEnhancedAudio()
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

//
//  AudioFileStore.swift
//  MeetSync
//
//  Helpers for locating and measuring on-disk audio. Recordings are addressed by
//  file name and resolved against the *current* Documents directory, so they keep
//  working even if the app container path changes between launches.
//

import Foundation

enum AudioFileStore {
    /// The app's Documents directory in the current container.
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Deterministic file name for a recording: `{meetingID}_{timestamp}.m4a`.
    static func fileName(meetingID: UUID, date: Date = Date()) -> String {
        "\(meetingID.uuidString)_\(date.fileTimestamp).m4a"
    }

    /// Total bytes used by every `.m4a` in Documents.
    static func totalAudioBytes() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return items
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .reduce(Int64(0)) { running, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return running + Int64(size)
            }
    }

    /// Delete a single audio file by name. Missing files are ignored.
    static func delete(fileName: String) {
        let url = documentsURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete every `.m4a` in Documents (used by "Delete All Data").
    static func deleteAllAudio() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in items where url.pathExtension.lowercased() == "m4a" {
            try? fm.removeItem(at: url)
        }
    }

    /// Human-readable byte count, e.g. "12.4 MB".
    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

//
//  TempFileCleaner.swift
//  Kurn
//
//  Removes temporary files created by the transcription pipeline (preprocessing,
//  VAD compaction, diarization, chunking, and Whisper upload bodies). Kept
//  separate from `TranscriptionService` so the cleanup logic can be invoked
//  both automatically at transcription start and manually from Settings.
//

import Foundation

enum TempFileCleaner {
    /// Known prefixes for pipeline temporary files created inside the app's
    /// temporary directory. Only files matching these prefixes are touched.
    static let prefixes = [
        "kurn_clean_",
        "kurn_vad_",
        "kurn_diar_",
        "kurn_chunk_"
    ]

    /// Sweep old temporary files left behind by killed/crashed transcriptions.
    /// Uses a 1-hour age threshold so it never touches files an in-flight
    /// transcription is still using; anything that old is almost certainly an
    /// orphan because no single stage should run for that long.
    /// Called automatically at the start of every `TranscriptionService.transcribe` run.
    static func cleanupOrphanedTempFiles() {
        _ = Self.cleanup(olderThan: 3600)
    }

    /// Force-remove all known temporary files and upload-body spool files.
    /// Returns the number of files and bytes removed. This is the user-triggered
    /// cleanup in Settings; it ignores the age threshold but only touches files
    /// with known prefixes inside the temporary directory, so recordings in
    /// `Documents/Recordings` are never affected.
    static func forceCleanup() -> (files: Int, bytes: Int64) {
        let result = Self.cleanup(olderThan: nil)
        AppLog.transcription.atNotice.notice("forceCleanupTempFiles: removed \(result.files, privacy: .public) file(s), \(result.bytes, privacy: .public) bytes")
        return result
    }

    private static func cleanup(olderThan: TimeInterval?) -> (files: Int, bytes: Int64) {
        let tmp = FileManager.default.temporaryDirectory
        let keys: [URLResourceKey] = [.nameKey, .creationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return (0, 0) }

        let cutoff = olderThan.map { Date().addingTimeInterval(-$0) }
        var removed = 0
        var removedBytes: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.nameKey, .creationDateKey, .fileSizeKey])
            let name = values?.name ?? file.lastPathComponent
            guard Self.prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            if let cutoff, let creationDate = values?.creationDate, creationDate >= cutoff { continue }
            let size = values?.fileSize ?? 0
            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
                removedBytes += Int64(size)
            } catch {
                AppLog.transcription.atDebug.debug("transcribe: could not remove temp file \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 {
            AppLog.transcription.atDebug.debug("transcribe: cleaned up \(removed, privacy: .public) temp file(s), \(removedBytes, privacy: .public) bytes")
        }

        // Also sweep the upload-body subdirectory.
        let uploadDir = tmp.appendingPathComponent("WhisperUploadBodies", isDirectory: true)
        if let uploadFiles = try? FileManager.default.contentsOfDirectory(
            at: uploadDir,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) {
            for file in uploadFiles where file.pathExtension == "multipart" {
                let values = try? file.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                if let cutoff, let creationDate = values?.creationDate, creationDate >= cutoff { continue }
                let size = values?.fileSize ?? 0
                do {
                    try FileManager.default.removeItem(at: file)
                    removed += 1
                    removedBytes += Int64(size)
                } catch {
                    AppLog.transcription.atDebug.debug("transcribe: could not remove upload body \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if removed > 0 {
            AppLog.transcription.atDebug.debug("transcribe: total temp files removed: \(removed, privacy: .public), \(removedBytes, privacy: .public) bytes")
        }
        return (removed, removedBytes)
    }
}

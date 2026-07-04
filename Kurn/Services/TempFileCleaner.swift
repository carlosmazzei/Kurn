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

    /// Return the files and bytes that `forceCleanup()` would remove right now.
    static func reclaimableSpace() -> (files: Int, bytes: Int64) {
        Self.scan(olderThan: nil, remove: false)
    }

    private static func cleanup(olderThan: TimeInterval?) -> (files: Int, bytes: Int64) {
        Self.scan(olderThan: olderThan, remove: true)
    }

    private static func scan(olderThan: TimeInterval?, remove: Bool) -> (files: Int, bytes: Int64) {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = olderThan.map { Date().addingTimeInterval(-$0) }

        let pipelineResult = sweep(directory: tmp, cutoff: cutoff, remove: remove) { _, name in
            Self.prefixes.contains(where: { name.hasPrefix($0) })
        }

        // Also sweep the upload-body subdirectory, excluding any file a
        // background upload task is still actively reading from disk.
        let uploadDir = tmp.appendingPathComponent("WhisperUploadBodies", isDirectory: true)
        let inFlight = WhisperBackgroundUploader.shared.inFlightBodyFilePaths()
        let uploadResult = sweep(directory: uploadDir, cutoff: cutoff, remove: remove) { file, _ in
            file.pathExtension == "multipart" && !inFlight.contains(file.path)
        }

        let removed = pipelineResult.files + uploadResult.files
        let removedBytes = pipelineResult.bytes + uploadResult.bytes
        if removed > 0 {
            AppLog.transcription.atDebug.debug("transcribe: cleaned up \(removed, privacy: .public) temp file(s), \(removedBytes, privacy: .public) bytes")
        }
        return (removed, removedBytes)
    }

    /// Remove every file in `directory` matching `isEligible` that is older
    /// than `cutoff`. A `nil` cutoff removes every eligible file regardless of
    /// age (used by `forceCleanup`). A file whose creation date can't be read
    /// is conservatively kept rather than removed, since an unreadable
    /// attribute can't prove the file is actually old enough to be an orphan.
    private static func sweep(
        directory: URL,
        cutoff: Date?,
        remove: Bool,
        isEligible: (URL, String) -> Bool
    ) -> (files: Int, bytes: Int64) {
        let keys: [URLResourceKey] = [.nameKey, .creationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return (0, 0) }

        var removed = 0
        var removedBytes: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.nameKey, .creationDateKey, .fileSizeKey])
            let name = values?.name ?? file.lastPathComponent
            guard isEligible(file, name) else { continue }
            if let cutoff {
                guard let creationDate = values?.creationDate, creationDate < cutoff else { continue }
            }
            let size = values?.fileSize ?? 0
            if !remove {
                removed += 1
                removedBytes += Int64(size)
                continue
            }
            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
                removedBytes += Int64(size)
            } catch {
                AppLog.transcription.atDebug.debug("transcribe: could not remove temp file \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return (removed, removedBytes)
    }
}

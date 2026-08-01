//
//  Recording.swift
//  Kurn
//
//  One continuous audio segment within a meeting, backed by an .m4a file in the
//  app's Documents directory.
//

import Foundation
import SwiftData

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    /// File name (not absolute path) within Documents. Resolved lazily so the
    /// recording survives the container path changing between launches.
    var fileName: String
    var duration: TimeInterval
    var recordedAt: Date
    var transcriptionStatusRaw: String
    var transcriptionModeRaw: String
    /// JSON-encoded `TranscriptionCheckpoint` while a chunked transcription is
    /// in flight (SwiftData can't store arbitrary Codable values directly).
    /// Cleared on success; kept on failure/interruption so the next attempt
    /// resumes from the last completed chunk instead of starting over.
    var transcriptionCheckpointData: Data?
    /// Size of the backing file in bytes, cached so storage UI and the recording
    /// compactor can rank meetings without stat-ing every file. `0` means
    /// "unknown" — rows created before this field existed, refreshed lazily by
    /// `RecordingRecovery`. The default value is also what lets SwiftData migrate
    /// the store lightly instead of needing a migration plan.
    var fileSize: Int64 = 0
    /// Tuning revision of the enhanced listening copy on disk. `0` means there is
    /// no copy; any other value that differs from
    /// `PlaybackEnhancementRenderer.currentVersion` means the copy was rendered
    /// with older settings and should be regenerated. One field answers both
    /// "does it exist?" and "is it stale?".
    ///
    /// Defaulted, like `fileSize`, so SwiftData migrates the store lightly rather
    /// than needing a migration plan.
    var enhancedAudioVersion: Int = 0
    /// Byte count of the enhanced copy, cached so the storage screen can total
    /// them without stat-ing every file.
    var enhancedFileSize: Int64 = 0

    @Relationship(deleteRule: .cascade, inverse: \Transcript.recording)
    var transcript: Transcript?

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        fileName: String,
        duration: TimeInterval,
        recordedAt: Date = Date(),
        transcriptionStatus: TranscriptionStatus = .none,
        transcriptionMode: TranscriptionMode = .onDevice,
        fileSize: Int64 = 0
    ) {
        self.id = id
        self.meeting = meeting
        self.fileName = fileName
        self.duration = duration
        self.recordedAt = recordedAt
        self.transcriptionStatusRaw = transcriptionStatus.rawValue
        self.transcriptionModeRaw = transcriptionMode.rawValue
        self.fileSize = fileSize
    }

    var transcriptionStatus: TranscriptionStatus {
        get { TranscriptionStatus(rawValue: transcriptionStatusRaw) ?? .none }
        set { transcriptionStatusRaw = newValue.rawValue }
    }

    var transcriptionMode: TranscriptionMode {
        get { TranscriptionMode(rawValue: transcriptionModeRaw) ?? .onDevice }
        set { transcriptionModeRaw = newValue.rawValue }
    }

    var transcriptionCheckpoint: TranscriptionCheckpoint? {
        get {
            guard let data = transcriptionCheckpointData else { return nil }
            return JSONStorage.decode(TranscriptionCheckpoint.self, from: data)
        }
        set {
            transcriptionCheckpointData = newValue.map(JSONStorage.encode)
        }
    }

    /// Absolute URL of the backing audio file in the current container.
    /// Resolves through `AudioFileStore` so the protected subdirectory is
    /// preferred and any pre-migration leftover in Documents is still found.
    var fileURL: URL {
        AudioFileStore.resolveURL(fileName: fileName)
    }

    /// Re-read the backing file's size from disk. Cheap (one `stat`), so callers
    /// that just wrote or replaced the file should always call it rather than
    /// computing the expected size.
    func refreshFileSize() {
        fileSize = AudioFileStore.byteSize(fileName: fileName)
    }

    /// Whether a usable enhanced copy exists: rendered by the current tuning *and*
    /// still on disk. The on-disk check matters because "Delete all data" and the
    /// storage screen can remove the file without touching the row.
    func hasEnhancedAudio(currentVersion: Int) -> Bool {
        enhancedAudioVersion == currentVersion
            && AudioFileStore.hasEnhancedAudio(fileName: fileName)
    }

    /// Forget the enhanced copy, after deleting it or finding it stale.
    func clearEnhancedAudio() {
        enhancedAudioVersion = 0
        enhancedFileSize = 0
    }

    /// Bit rate the file is actually stored at, or `nil` when either input is
    /// unknown. Used to decide whether re-encoding a recording would gain
    /// anything, so it deliberately reports the *file's* rate (which includes
    /// container overhead) rather than the encoder setting it was made with.
    var effectiveBitRate: Int? {
        guard fileSize > 0, duration > 0 else { return nil }
        return Int(Double(fileSize) * 8 / duration)
    }
}

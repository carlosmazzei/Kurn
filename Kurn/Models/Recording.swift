//
//  Recording.swift
//  Kurn
//
//  One continuous audio segment within a meeting, backed by an .m4a file in the
//  app's Documents directory.
//

import Foundation
import KurnCore
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
    var captureStateRaw: String = RecordingCaptureState.ready.rawValue
    var captureRecoveryReasonRaw: String?
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
    /// JSON-encoded `[Highlight]` marked during this recording. SwiftData
    /// can't store arbitrary Codable arrays directly (see `JSONStorage`), and
    /// — like `fileSize`/`enhancedAudioVersion` above — the inline default
    /// lets SwiftData migrate existing rows lightly instead of needing a
    /// migration plan; `Data()` decodes to `[]` through `JSONStorage.decode`'s
    /// failure fallback.
    var highlightsData: Data = Data()
    /// JSON-encoded `[String: [Float]]`: this recording's own diarization
    /// run's speaker label → voiceprint, same `JSONStorage` pattern as
    /// `highlightsData` above.
    ///
    /// Speakers are meeting-scoped but a diarization run is per-recording, and
    /// its labels are only unique *within* that run — the diarizer numbers
    /// them independently every time, so a second recording's "Speaker 1" is
    /// not the first recording's "Speaker 1". `TranscriptionViewModel.syncSpeakers`
    /// used to be handed only the voiceprints of whichever recording had just
    /// finished, so reconciling any other recording in the meeting fell back
    /// to matching by that ambiguous label string and could silently attach a
    /// name to the wrong person. Persisting each recording's own voiceprints
    /// here is what lets every recording be matched by voice, independently,
    /// on every sync.
    var speakerVoiceprintsData: Data = Data()

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
        captureState: RecordingCaptureState = .ready,
        captureRecoveryReason: CaptureRecoveryReason? = nil,
        fileSize: Int64 = 0,
        highlights: [Highlight] = []
    ) {
        self.id = id
        self.meeting = meeting
        self.fileName = fileName
        self.duration = duration
        self.recordedAt = recordedAt
        self.transcriptionStatusRaw = transcriptionStatus.rawValue
        self.transcriptionModeRaw = transcriptionMode.rawValue
        self.captureStateRaw = captureState.rawValue
        self.captureRecoveryReasonRaw = captureRecoveryReason?.rawValue
        self.fileSize = fileSize
        self.highlightsData = JSONStorage.encode(highlights)
    }

    var captureState: RecordingCaptureState {
        get { RecordingCaptureState(rawValue: captureStateRaw) ?? .recoveryNeeded }
        set { captureStateRaw = newValue.rawValue }
    }

    var captureRecoveryReason: CaptureRecoveryReason? {
        get { captureRecoveryReasonRaw.flatMap(CaptureRecoveryReason.init(rawValue:)) }
        set { captureRecoveryReasonRaw = newValue?.rawValue }
    }

    var isReadyForConsumption: Bool { captureState == .ready }

    var transcriptionStatus: TranscriptionStatus {
        get { TranscriptionStatus(rawValue: transcriptionStatusRaw) ?? .none }
        set { transcriptionStatusRaw = newValue.rawValue }
    }

    var transcriptionMode: TranscriptionMode {
        get { TranscriptionMode(rawValue: transcriptionModeRaw) ?? .onDevice }
        set { transcriptionModeRaw = newValue.rawValue }
    }

    var transcriptionCheckpoint: TranscriptionCheckpoint? {
        get { transcriptionCheckpointOutcome.decodedValue }
        set {
            if let newValue {
                // A failed encode keeps the previous checkpoint bytes: an
                // older resumable point is strictly better than none. Clearing
                // is always the explicit `transcriptionCheckpointData = nil`.
                transcriptionCheckpointData =
                    JSONStorage.encodeAuthoritative(newValue) ?? transcriptionCheckpointData
            } else {
                transcriptionCheckpointData = nil
            }
        }
    }

    /// The checkpoint decode with corruption kept distinct from absence: a
    /// checkpoint that fails to decode or verify must never be treated as "no
    /// checkpoint" and silently spliced over or redone — for cloud engines
    /// that ambiguity is repeated paid work. The corrupted bytes stay in
    /// `transcriptionCheckpointData` (until the next run overwrites them) so
    /// diagnostics have something to work with.
    var transcriptionCheckpointOutcome: JSONDecodeOutcome<TranscriptionCheckpoint> {
        guard let data = transcriptionCheckpointData else { return .empty }
        return JSONStorage.decodeAuthoritative(TranscriptionCheckpoint.self, from: data)
    }

    var highlights: [Highlight] {
        get { JSONStorage.decode([Highlight].self, from: highlightsData) }
        set { highlightsData = JSONStorage.encode(newValue) }
    }

    var speakerVoiceprints: [String: [Float]] {
        get { JSONStorage.decode([String: [Float]].self, from: speakerVoiceprintsData) ?? [:] }
        set { speakerVoiceprintsData = JSONStorage.encode(newValue) }
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

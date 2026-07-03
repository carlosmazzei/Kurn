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

    @Relationship(deleteRule: .cascade, inverse: \Transcript.recording)
    var transcript: Transcript?

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        fileName: String,
        duration: TimeInterval,
        recordedAt: Date = Date(),
        transcriptionStatus: TranscriptionStatus = .none,
        transcriptionMode: TranscriptionMode = .onDevice
    ) {
        self.id = id
        self.meeting = meeting
        self.fileName = fileName
        self.duration = duration
        self.recordedAt = recordedAt
        self.transcriptionStatusRaw = transcriptionStatus.rawValue
        self.transcriptionModeRaw = transcriptionMode.rawValue
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
}

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

    /// Absolute URL of the backing audio file in the current container.
    var fileURL: URL {
        AudioFileStore.documentsURL.appendingPathComponent(fileName)
    }
}

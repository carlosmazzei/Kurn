//
//  Meeting.swift
//  Kurn
//
//  A named meeting session that groups one or more audio recordings, their
//  transcripts, detected speakers, and an optional AI summary.
//

import Foundation
import SwiftData

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var notes: String
    /// Stored raw value of `MeetingLanguage` for the transcription preference.
    var languageRaw: String

    // Deleting a meeting tears down everything that belongs to it.
    @Relationship(deleteRule: .cascade, inverse: \Recording.meeting)
    var recordings: [Recording]

    @Relationship(deleteRule: .cascade, inverse: \Speaker.meeting)
    var speakers: [Speaker]

    @Relationship(deleteRule: .cascade, inverse: \Summary.meeting)
    var summary: Summary?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        notes: String = "",
        language: MeetingLanguage = .autoDetect
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.notes = notes
        self.languageRaw = language.rawValue
        self.recordings = []
        self.speakers = []
        self.summary = nil
    }

    var language: MeetingLanguage {
        get { MeetingLanguage(rawValue: languageRaw) ?? .autoDetect }
        set { languageRaw = newValue.rawValue }
    }

    /// Sum of all recording durations.
    var totalDuration: TimeInterval {
        recordings.reduce(0) { $0 + $1.duration }
    }

    /// Aggregate transcription status shown as a badge in the list.
    var aggregateStatus: TranscriptionStatus {
        guard !recordings.isEmpty else { return .none }
        if recordings.contains(where: { $0.transcriptionStatus == .inProgress }) {
            return .inProgress
        }
        if recordings.allSatisfy({ $0.transcriptionStatus == .done }) {
            return .done
        }
        if recordings.contains(where: { $0.transcriptionStatus == .failed }) {
            return .failed
        }
        return .none
    }

    var hasAnyTranscript: Bool {
        recordings.contains { $0.transcript != nil }
    }
}

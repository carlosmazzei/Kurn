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

    /// Seconds from the start of the meeting to the start of `recording`, i.e.
    /// the sum of every chronologically earlier recording's duration. Used to
    /// shift each segment's recording-relative timestamps into absolute meeting
    /// time when displaying or exporting a multi-segment transcript. Based on all
    /// recordings (not only transcribed ones) so an untranscribed gap doesn't
    /// misalign later segments.
    func startOffset(of recording: Recording) -> TimeInterval {
        recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .prefix { $0.id != recording.id }
            .reduce(0) { $0 + $1.duration }
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

    /// Whether this meeting contains `needle` anywhere the meetings list
    /// searches: title, notes, or any recording's transcript plain text. Cheap
    /// string fields are checked first so the transcript JSON decode (per
    /// `Transcript.plainText`) is skipped whenever an earlier field matches.
    /// Match is case-insensitive and locale-aware. An empty `needle` matches.
    func matches(search needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(needle) { return true }
        if notes.localizedCaseInsensitiveContains(needle) { return true }
        for recording in recordings {
            if let plain = recording.transcript?.plainText,
               plain.localizedCaseInsensitiveContains(needle) {
                return true
            }
        }
        return false
    }
}

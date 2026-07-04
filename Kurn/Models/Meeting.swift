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
    /// Short AI-generated title produced after the first transcription completes.
    /// Nil until generated; displayed in the meetings list instead of a raw
    /// transcript excerpt. Cleared on re-transcription so it stays in sync.
    var aiTitle: String?
    /// Stored raw value of `MeetingLanguage` for the transcription preference.
    var languageRaw: String
    /// User-pinned meeting. Surfaced as a star on the card and as the
    /// `Favorites` library bucket. Lightweight-additive: defaults to `false`
    /// for meetings created before this field existed.
    var isFavorite: Bool = false
    /// When non-nil, the meeting is archived: hidden from the default list
    /// but still in storage and accessible from the `Archive` library bucket.
    /// Tracking the moment of archival lets future versions sort the Archive
    /// view by "recently archived" without a second field.
    var archivedAt: Date?
    /// Owning user folder, or `nil` when the meeting lives in the `Inbox`
    /// virtual bucket. The inverse is defined on `Folder.meetings` with
    /// `.nullify`, so deleting a folder detaches its meetings instead of
    /// destroying them.
    var folder: Folder?

    /// User-defined tags attached to this meeting. The inverse is defined on
    /// `Tag.meetings` with `.nullify`, so deleting a tag detaches it from
    /// meetings without deleting them.
    var tags: [Tag] = []

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
        language: MeetingLanguage = .autoDetect,
        isFavorite: Bool = false,
        archivedAt: Date? = nil,
        folder: Folder? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.notes = notes
        self.languageRaw = language.rawValue
        self.isFavorite = isFavorite
        self.archivedAt = archivedAt
        self.folder = folder
        self.recordings = []
        self.speakers = []
        self.summary = nil
    }

    /// Convenience: whether the meeting is currently archived.
    var isArchived: Bool { archivedAt != nil }

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
        if recordings.contains(where: { $0.transcriptionStatus == .pending }) {
            return .pending
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

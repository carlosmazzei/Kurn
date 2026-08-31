//
//  Transcript.swift
//  Kurn
//
//  A full transcript for one recording. Speaker-attributed segments are encoded
//  to JSON `Data` because SwiftData cannot persist `[TranscriptSegment]` directly.
//

import Foundation
import KurnCore
import SwiftData

@Model
final class Transcript {
    @Attribute(.unique) var id: UUID
    var recording: Recording?
    /// JSON-encoded `[TranscriptSegment]`.
    var segmentsData: Data
    /// Detected BCP-47 locale, e.g. "pt-BR".
    var language: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        recording: Recording? = nil,
        segments: [TranscriptSegment] = [],
        language: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recording = recording
        // `?? Data()` only ever applies to the `= []` default here, which
        // trivially encodes; a real payload that fails to encode goes
        // through `TranscriptionViewModel.saveTranscript`'s explicit
        // pre-check instead, which fails the save rather than reaching this
        // fallback. See `JSONStorage.encodeAuthoritative`.
        self.segmentsData = JSONStorage.encodeAuthoritative(segments) ?? Data()
        self.language = language
        self.createdAt = createdAt
    }

    var segments: [TranscriptSegment] {
        get { JSONStorage.decodeAuthoritative([TranscriptSegment].self, from: segmentsData).decodedValue ?? [] }
        // A failed encode leaves the previously-stored bytes untouched
        // rather than blanking them — losing a transcript to a rare
        // encoding failure on an in-place edit would be worse than keeping
        // the pre-edit content.
        set { segmentsData = JSONStorage.encodeAuthoritative(newValue) ?? segmentsData }
    }

    /// Whether the stored segments failed to decode or verify — distinct
    /// from a genuinely empty transcript, which `segments` alone cannot
    /// tell apart from corruption. Surfaced in `MeetingDetailView`'s
    /// transcript tab rather than rendered as "no speech detected".
    var isSegmentsDataCorrupted: Bool {
        JSONStorage.decodeAuthoritative([TranscriptSegment].self, from: segmentsData).isCorrupted
    }

    /// Flattened plain text, one line per segment, for sharing/export.
    var plainText: String {
        segments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
    }
}

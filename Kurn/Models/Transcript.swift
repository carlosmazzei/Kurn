//
//  Transcript.swift
//  Kurn
//
//  A full transcript for one recording. Speaker-attributed segments are encoded
//  to JSON `Data` because SwiftData cannot persist `[TranscriptSegment]` directly.
//

import Foundation
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
        self.segmentsData = JSONStorage.encode(segments)
        self.language = language
        self.createdAt = createdAt
    }

    var segments: [TranscriptSegment] {
        get { JSONStorage.decode([TranscriptSegment].self, from: segmentsData) }
        set { segmentsData = JSONStorage.encode(newValue) }
    }

    /// Flattened plain text, one line per segment, for sharing/export.
    var plainText: String {
        segments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
    }
}

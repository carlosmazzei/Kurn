//
//  Highlight.swift
//  Kurn
//
//  A one-tap marked instant during a live recording.
//

import Foundation

/// A single marked instant during a live recording ("this moment matters"),
/// captured with a one-tap gesture — deliberately no label/note field, since
/// adding one would require a keyboard mid-recording. `timestamp` is
/// recording-relative, matching `TranscriptSegment.startTime`'s convention.
/// Stored inside `Recording` as JSON `Data`, same pattern as
/// `Transcript.segments`.
struct Highlight: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var timestamp: TimeInterval
    var createdAt: Date = Date()
}

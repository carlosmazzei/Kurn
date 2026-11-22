// A value snapshot shared by fingerprinting and citation validation. The host
// hashes canonicalData with CryptoKit; no cryptography dependency in KurnCore.
import Foundation

public enum KnowledgeTranscriptSnapshotError: String, Error, Sendable {
    case duplicateSegmentID = "duplicate_segment_id"
    case invalidTimeRange = "invalid_time_range"
    case invalidConfidence = "invalid_confidence"
    case unreadableTranscript = "unreadable_transcript"
}

public struct KnowledgeTranscriptSnapshot: Sendable {
    public static let encodingVersion = 1
    public let canonicalData: Data
    public let sourceSegments: [KnowledgeSourceSegment]

    /// Array order is transcript order, never sorted by timestamp (overlapping
    /// speech is valid). UUIDs are the anchors, scoped to this revision.
    /// The encoding is versioned, length-prefixed UTF-8 fields: domain, language,
    /// count, then id/speaker/start/end/text/confidence for each segment. Times
    /// and confidence use IEEE bit patterns, preserving sub-millisecond edits.
    /// Display names, creation dates and pipeline reports are not source text.
    public init(segments: [TranscriptSegment], language: String) throws {
        var fields = ["kurn.knowledge-transcript.v\(Self.encodingVersion)", language, String(segments.count)]
        var sources: [KnowledgeSourceSegment] = []
        var ids: Set<UUID> = []
        for segment in segments {
            guard ids.insert(segment.id).inserted else { throw KnowledgeTranscriptSnapshotError.duplicateSegmentID }
            guard segment.startTime.isFinite, segment.endTime.isFinite,
                  segment.startTime >= 0, segment.endTime > segment.startTime,
                  let start = Int(exactly: (segment.startTime * 1_000).rounded(.down)),
                  let end = Int(exactly: (segment.endTime * 1_000).rounded(.up)) else {
                throw KnowledgeTranscriptSnapshotError.invalidTimeRange
            }
            if let confidence = segment.confidence, !confidence.isFinite {
                throw KnowledgeTranscriptSnapshotError.invalidConfidence
            }
            let id = segment.id.uuidString.lowercased()
            fields += [id, segment.speakerLabel, String(segment.startTime.bitPattern),
                       String(segment.endTime.bitPattern), segment.text,
                       segment.confidence.map { String($0.bitPattern) } ?? "nil"]
            sources.append(KnowledgeSourceSegment(id: id, startMs: start, endMs: end, text: segment.text))
        }
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            data.append(contentsOf: "\(bytes.count):".utf8)
            data.append(bytes)
        }
        self.canonicalData = data
        self.sourceSegments = sources
    }
}

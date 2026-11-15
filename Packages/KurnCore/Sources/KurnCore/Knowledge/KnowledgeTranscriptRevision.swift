//
//  KnowledgeTranscriptRevision.swift
//  KurnCore
//
//  A meeting's transcript as the Knowledge Engine cites it (K1.3, CLAUDE.md
//  "Knowledge Engine decisions"): every recording's segments on one meeting
//  timeline, each with a short positional anchor (`s1`, `s2`, …) that
//  extraction cites and the evidence validator checks, plus a canonical
//  encoding whose digest is the revision's fingerprint.
//
//  `Transcript` keeps no history and a re-transcription regenerates every
//  `TranscriptSegment.id`, so an anchor only means something together with
//  the fingerprint of the revision it was taken from: evidence stores both,
//  and evidence whose fingerprint no longer matches is unavailable, never
//  re-pointed. The encoding covers what a citation depends on — order,
//  recording, times, speaker and text — and nothing else (confidence is left
//  out). It is length-prefixed, so no text can forge a field boundary.
//  Hashing needs CryptoKit and is the app's job.
//

import Foundation

/// One recording's transcript and where it starts on the meeting timeline.
public struct KnowledgeTranscriptSource: Hashable, Sendable {
    public let recordingID: UUID
    public let offset: TimeInterval
    public let segments: [TranscriptSegment]

    public init(recordingID: UUID, offset: TimeInterval, segments: [TranscriptSegment]) {
        self.recordingID = recordingID
        self.offset = offset
        self.segments = segments
    }
}

/// Where an anchor points back to in the stored transcript.
public struct KnowledgeSegmentLocation: Hashable, Sendable {
    public let recordingID: UUID
    public let segmentID: UUID
    public let speakerLabel: String
}

public struct KnowledgeTranscriptRevision: Sendable {
    /// Bumped when the encoding changes; it is part of the encoded bytes, so
    /// a new version never collides with an old fingerprint.
    public static let encodingVersion = 1

    /// The segments in transcript order, anchored, on the meeting timeline.
    public let segments: [KnowledgeSourceSegment]
    /// The bytes the fingerprint is the digest of.
    public let canonicalEncoding: Data
    private let locations: [String: KnowledgeSegmentLocation]

    /// `sources` in chronological order, as the meeting plays them.
    public init(sources: [KnowledgeTranscriptSource]) {
        var segments: [KnowledgeSourceSegment] = []
        var locations: [String: KnowledgeSegmentLocation] = [:]
        var encoding = Data()
        Self.append("kurn.transcript-revision", to: &encoding)
        Self.append(String(Self.encodingVersion), to: &encoding)
        for source in sources {
            for segment in source.segments {
                let anchor = Self.anchor(at: segments.count)
                let start = Self.milliseconds(source.offset + segment.startTime)
                let end = Self.milliseconds(source.offset + segment.endTime)
                segments.append(KnowledgeSourceSegment(id: anchor, startMs: start, endMs: end, text: segment.text))
                locations[anchor] = KnowledgeSegmentLocation(
                    recordingID: source.recordingID, segmentID: segment.id, speakerLabel: segment.speakerLabel
                )
                for field in [source.recordingID.uuidString, String(start), String(end), segment.speakerLabel, segment.text] {
                    Self.append(field, to: &encoding)
                }
            }
        }
        self.segments = segments
        self.locations = locations
        self.canonicalEncoding = encoding
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// The stored segment an anchor of this revision points to.
    public func location(of anchor: String) -> KnowledgeSegmentLocation? {
        locations[anchor]
    }

    /// A validator for citations of this revision.
    public var validator: KnowledgeEvidenceValidator {
        KnowledgeEvidenceValidator(segments: segments)
    }

    /// `s1`, `s2`, …: short enough to cost little in a prompt.
    public static func anchor(at index: Int) -> String {
        "s\(index + 1)"
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((seconds * 1000).rounded())
    }

    private static func append(_ field: String, to data: inout Data) {
        let bytes = Data(field.utf8)
        data.append(contentsOf: Array("\(bytes.count):".utf8))
        data.append(bytes)
    }
}

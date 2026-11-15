//
//  KnowledgeEvidenceValidator.swift
//  KurnCore
//
//  The host-side check every extracted citation passes before an assertion
//  can be committed (spec §7.4): the cited segments exist in the transcript
//  revision being compiled, are distinct, contiguous and in transcript order
//  (so a quote can never be stitched across a skipped "not" or a reordered
//  line), the quote is verbatim in their text under a conservative
//  normalization, and both ends of any time range fall inside a cited segment.
//  A model's claim that its quote is exact is never trusted. Quote hashing
//  needs a cryptographic digest, which is the app's job (CryptoKit); this
//  type stays Foundation-only so it runs on Linux.
//

import Foundation

/// One segment of the transcript revision being compiled.
public struct KnowledgeSourceSegment: Hashable, Sendable {
    public let id: String
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(id: String, startMs: Int, endMs: Int, text: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// A citation as the extraction model returned it.
public struct KnowledgeEvidenceClaim: Hashable, Sendable {
    public let segmentIDs: [String]
    public let quote: String
    public let startMs: Int?
    public let endMs: Int?

    public init(segmentIDs: [String], quote: String, startMs: Int? = nil, endMs: Int? = nil) {
        self.segmentIDs = segmentIDs
        self.quote = quote
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// Why a citation was rejected. Fixed vocabulary, safe to log; never carries text.
public enum KnowledgeEvidenceRejection: String, Codable, Sendable, CaseIterable, Error {
    case noSegments = "no_segments"
    case unknownSegment = "unknown_segment"
    case repeatedSegment = "repeated_segment"
    case segmentsNotContiguous = "segments_not_contiguous"
    case emptyQuote = "empty_quote"
    case quoteNotVerbatim = "quote_not_verbatim"
    case invertedTimeRange = "inverted_time_range"
    case timeOutsideSegments = "time_outside_segments"
}

/// A citation that passed: its segments in cited order and its span.
public struct KnowledgeValidatedEvidence: Hashable, Sendable {
    public let segmentIDs: [String]
    /// The quote as normalized for comparison.
    public let normalizedQuote: String
    public let startMs: Int
    public let endMs: Int
}

public struct KnowledgeEvidenceValidator: Sendable {
    private let segments: [String: KnowledgeSourceSegment]
    /// Each segment's position in the transcript.
    private let positions: [String: Int]

    /// `segments` in transcript order.
    public init(segments: [KnowledgeSourceSegment]) {
        self.segments = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.positions = Dictionary(segments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func validate(_ claim: KnowledgeEvidenceClaim) -> Result<KnowledgeValidatedEvidence, KnowledgeEvidenceRejection> {
        guard !claim.segmentIDs.isEmpty else { return .failure(.noSegments) }
        guard Set(claim.segmentIDs).count == claim.segmentIDs.count else { return .failure(.repeatedSegment) }
        var cited: [KnowledgeSourceSegment] = []
        var order: [Int] = []
        for id in claim.segmentIDs {
            guard let segment = segments[id], let position = positions[id] else { return .failure(.unknownSegment) }
            cited.append(segment)
            order.append(position)
        }
        // Consecutive in the transcript and cited in its order: no gap a quote
        // could jump, no reordering it could exploit.
        guard zip(order, order.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else {
            return .failure(.segmentsNotContiguous)
        }
        let quote = Self.normalized(claim.quote)
        guard !quote.isEmpty else { return .failure(.emptyQuote) }
        let text = Self.normalized(cited.map(\.text).joined(separator: " "))
        guard text.contains(quote) else { return .failure(.quoteNotVerbatim) }

        let lower = cited.map(\.startMs).min() ?? 0
        let upper = cited.map(\.endMs).max() ?? 0
        let start = claim.startMs ?? lower
        let end = claim.endMs ?? upper
        guard start < end else { return .failure(.invertedTimeRange) }
        // The range may cross a pause between cited segments, but each end
        // must be inside one of them — never wholly in a gap.
        let startInside = cited.contains { start >= $0.startMs && start < $0.endMs }
        let endInside = cited.contains { end > $0.startMs && end <= $0.endMs }
        guard start >= lower, end <= upper, startInside, endInside else { return .failure(.timeOutsideSegments) }
        return .success(KnowledgeValidatedEvidence(segmentIDs: claim.segmentIDs, normalizedQuote: quote, startMs: start, endMs: end))
    }

    /// Conservative: Unicode canonical composition, typographic quotes and
    /// apostrophes folded to ASCII, whitespace runs collapsed, ends trimmed.
    /// Case, punctuation and diacritics are kept, so a quote still has to be
    /// what was said.
    public static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.map { character -> Character in
            switch character {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}": "'"
            case "\u{201C}", "\u{201D}", "\u{201F}", "\u{2033}": "\""
            default: character
            }
        }
        return String(folded)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

import Foundation

public enum ChunkTimestampNormalization {
    public static let leadingBoundaryTolerance: TimeInterval = 1
    public static let trailingBoundaryTolerance: TimeInterval = TranscriptIntegrityGate.boundsSlack
    public static let inversionTolerance: TimeInterval = 0.1

    public struct Bounds: Sendable {
        public let offset: TimeInterval
        public let duration: TimeInterval?

        public init(offset: TimeInterval, duration: TimeInterval?) {
            self.offset = offset
            self.duration = duration
        }
    }

    public enum Failure: String, Error, Sendable {
        case invalidDuration
        case invalidOffset
        case invalidChunkPlan
        case nonFiniteTimestamp
        case invertedRange
        case outOfBounds
        case orphanedCheckpointSpans
    }

    public static func validate(_ chunks: [Bounds]) throws {
        for (index, chunk) in chunks.enumerated() {
            try validate(duration: chunk.duration, offset: chunk.offset)
            if index > 0, chunk.offset <= chunks[index - 1].offset {
                throw Failure.invalidChunkPlan
            }
        }
    }

    public static func normalize(
        _ transcript: RawTranscript,
        duration: TimeInterval?,
        offset: TimeInterval = 0
    ) throws -> RawTranscript {
        try validate(duration: duration, offset: offset)
        var result = transcript
        result.spans = try transcript.spans.map { span in
            var normalized = span
            (normalized.start, normalized.end) = try range(start: span.start, end: span.end, duration: duration, offset: offset)
            return normalized
        }
        result.speakerTurns = try transcript.speakerTurns.map { turns in
            try turns.map { turn in
                var normalized = turn
                (normalized.start, normalized.end) = try range(start: turn.start, end: turn.end, duration: duration, offset: offset)
                return normalized
            }
        }
        return result
    }

    public static func normalizeCompletedSpans(_ spans: [TranscribedSpan], chunks: [Bounds]) throws -> [TranscribedSpan] {
        try validate(chunks)
        guard !chunks.isEmpty else {
            guard spans.isEmpty else { throw Failure.orphanedCheckpointSpans }
            return spans
        }
        return try spans.map { span in
            guard span.start.isFinite, span.end.isFinite else { throw Failure.nonFiniteTimestamp }
            var index = chunks.lastIndex { $0.offset <= span.start } ?? 0
            if index + 1 < chunks.count,
               chunks[index + 1].offset - span.start <= leadingBoundaryTolerance,
               span.end - chunks[index + 1].offset > leadingBoundaryTolerance {
                index += 1
            }
            return try completedSpan(span, bounds: chunks[index])
        }
    }

    private static func completedSpan(_ span: TranscribedSpan, bounds: Bounds) throws -> TranscribedSpan {
        var normalized = span
        (normalized.start, normalized.end) = try range(
            start: span.start - bounds.offset,
            end: span.end - bounds.offset,
            duration: bounds.duration,
            offset: bounds.offset
        )
        return normalized
    }

    private static func validate(duration: TimeInterval?, offset: TimeInterval) throws {
        guard offset.isFinite, offset >= 0 else { throw Failure.invalidOffset }
        if let duration {
            guard duration.isFinite, duration >= 0 else { throw Failure.invalidDuration }
            guard (offset + duration).isFinite else { throw Failure.invalidOffset }
        }
    }

    private static func range(
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval?,
        offset: TimeInterval
    ) throws -> (TimeInterval, TimeInterval) {
        guard start.isFinite, end.isFinite else { throw Failure.nonFiniteTimestamp }
        guard start - end <= inversionTolerance + 1e-9 else { throw Failure.invertedRange }
        guard start >= -leadingBoundaryTolerance, end >= -leadingBoundaryTolerance else { throw Failure.outOfBounds }
        if let duration {
            guard start - duration <= trailingBoundaryTolerance, end - duration <= trailingBoundaryTolerance else {
                throw Failure.outOfBounds
            }
        }
        let upper = duration ?? .greatestFiniteMagnitude
        let normalizedStart = min(upper, max(0, start))
        let normalizedEnd = max(normalizedStart, min(upper, max(0, end)))
        let absoluteStart = normalizedStart + offset
        let absoluteEnd = normalizedEnd + offset
        guard absoluteStart.isFinite, absoluteEnd.isFinite else { throw Failure.nonFiniteTimestamp }
        return (absoluteStart, absoluteEnd)
    }
}

//
//  DiarizerSegmentLabeling.swift
//  KurnCore
//
//  The engine-independent half of turning a neural diarizer's raw output into
//  the app's speaker turns, and of reporting its progress. `FluidAudioDiarizer`
//  only reads FluidAudio's types into these values.
//

import Foundation

/// One segment as a diarizer reports it: an opaque speaker id and its bounds.
public struct DiarizerSegment: Sendable, Hashable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public enum DiarizerSegmentLabeling {
    /// Map opaque speaker ids to "Speaker N" labels — 1-indexed, in order of
    /// first appearance in time, the same scheme the heuristic engine uses — and
    /// return the turns sorted by start.
    public static func turns(from segments: [DiarizerSegment]) -> [SpeakerTurn] {
        var labelByID: [String: String] = [:]
        return segments.sorted { $0.start < $1.start }.map { segment in
            let label = labelByID[segment.speakerID] ?? {
                let next = "Speaker \(labelByID.count + 1)"
                labelByID[segment.speakerID] = next
                return next
            }()
            return SpeakerTurn(speakerLabel: label, start: segment.start, end: segment.end)
        }
    }

    /// Distinct speaker ids, the signal that decides whether a collapse rescue
    /// is worth attempting.
    public static func distinctSpeakerCount(in segments: [DiarizerSegment]) -> Int {
        Set(segments.map(\.speakerID)).count
    }
}

/// Throttles a chunk-by-chunk progress callback: reports a fraction only when
/// the integer percentage moves, and asks for a log line on the first chunk,
/// the last one, and each decile in between.
public enum ChunkProgressSampler {
    public struct Step: Equatable, Sendable {
        /// The fraction to report, or `nil` when the percentage did not move.
        public var fraction: Double?
        public var percent: Int
        public var shouldLog: Bool
        public var isFinished: Bool
        /// Seconds left at the current rate, or `0` before any chunk finished.
        public var estimatedRemaining: TimeInterval
    }

    public static func step(processed: Int, total: Int, elapsed: TimeInterval) -> Step {
        let safeTotal = max(1, total)
        let done = min(max(0, processed), safeTotal)
        let percent = done * 100 / safeTotal
        let previousPercent = max(0, done - 1) * 100 / safeTotal
        let crossedDecile = percent / 10 > previousPercent / 10
        let remaining = done > 0 ? elapsed * Double(safeTotal - done) / Double(done) : 0
        return Step(
            fraction: percent > previousPercent ? Double(done) / Double(safeTotal) : nil,
            percent: percent,
            shouldLog: done == 1 || done == safeTotal || crossedDecile,
            isFinished: done == safeTotal,
            estimatedRemaining: remaining
        )
    }
}

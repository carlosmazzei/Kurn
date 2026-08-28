//
//  TranscriptFusion.swift
//  Kurn
//
//  Pure fusion of transcription spans with diarization speaker turns into
//  speaker-attributed `TranscriptSegment`s. Extracted from `TranscriptionService`
//  so the attribution/merging logic — which has no I/O and is fully
//  deterministic — can be unit tested directly.
//

import Foundation
import KurnCore

enum TranscriptFusion {

    /// Default cap on a single fused segment's spoken duration before it's split.
    static let defaultMaxSegmentDuration: TimeInterval = 30

    /// Attribute each text span to a speaker turn, then merge consecutive
    /// same-speaker spans into segments (capped at `maxSegmentDuration`).
    static func segments(
        spans: [TranscribedSpan],
        turns: [SpeakerTurn],
        maxSegmentDuration: TimeInterval = defaultMaxSegmentDuration
    ) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return [] }
        let attributableSpans = spans.flatMap {
            splitCoarseSpan($0, at: turns, maxSegmentDuration: maxSegmentDuration)
        }

        var segments: [TranscriptSegment] = []
        var currentLabel: String?
        var currentText: [String] = []
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var confidenceSum: Float = 0
        var confidenceCount = 0

        func flush() {
            guard let label = currentLabel, !currentText.isEmpty else { return }
            let text = currentText.joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let confidence = confidenceCount > 0 ? confidenceSum / Float(confidenceCount) : nil
            segments.append(
                TranscriptSegment(
                    speakerLabel: label,
                    startTime: currentStart,
                    endTime: currentEnd,
                    text: text,
                    confidence: confidence
                )
            )
            currentText = []
            confidenceSum = 0
            confidenceCount = 0
        }

        for span in attributableSpans {
            let label = speakerLabel(for: span, in: turns)
            let wouldExceed = currentLabel != nil
                && (span.end - currentStart) > maxSegmentDuration

            if label != currentLabel || wouldExceed {
                flush()
                currentLabel = label
                currentStart = span.start
            }
            currentText.append(span.text)
            currentEnd = span.end
            if let confidence = span.confidence {
                confidenceSum += confidence
                confidenceCount += 1
            }
        }
        flush()

        return segments
    }

    /// Some ASR engines only return one text result for the entire recording.
    /// Giving that result to `speakerLabel(for:)` attributes every word to the
    /// speaker with the greatest total overlap, discarding otherwise valid
    /// diarization. For a long span crossing speaker changes, distribute its
    /// words over the overlapping turns in time order. This is necessarily an
    /// estimate until the ASR exposes word timestamps, but it preserves all
    /// detected speakers and keeps the text in its original order.
    private static func splitCoarseSpan(
        _ span: TranscribedSpan,
        at turns: [SpeakerTurn],
        maxSegmentDuration: TimeInterval
    ) -> [TranscribedSpan] {
        guard span.end - span.start > maxSegmentDuration else { return [span] }

        let overlaps = turns.compactMap { turn -> (turn: SpeakerTurn, duration: TimeInterval)? in
            let start = max(span.start, turn.start)
            let end = min(span.end, turn.end)
            guard end > start else { return nil }
            return (
                SpeakerTurn(speakerLabel: turn.speakerLabel, start: start, end: end),
                end - start
            )
        }
        guard Set(overlaps.map { $0.turn.speakerLabel }).count > 1 else { return [span] }

        let words = span.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= overlaps.count else { return [span] }
        let totalDuration = overlaps.reduce(0) { $0 + $1.duration }
        guard totalDuration > 0 else { return [span] }

        var result: [TranscribedSpan] = []
        var wordStart = 0
        var elapsed: TimeInterval = 0
        for (index, overlap) in overlaps.enumerated() {
            elapsed += overlap.duration
            let wordEnd = index == overlaps.count - 1
                ? words.count
                : max(wordStart + 1, min(words.count, Int((elapsed / totalDuration * Double(words.count)).rounded())))
            guard wordEnd > wordStart else { continue }
            result.append(
                TranscribedSpan(
                    text: words[wordStart..<wordEnd].joined(separator: " "),
                    start: overlap.turn.start,
                    end: overlap.turn.end,
                    confidence: span.confidence
                )
            )
            wordStart = wordEnd
        }
        return wordStart == words.count ? result : [span]
    }

    /// Pick the speaker who holds the most of the span's *duration*, falling
    /// back to the nearest turn by distance when the span overlaps nothing.
    ///
    /// Overlap totals rather than the span's midpoint: ASR spans routinely
    /// straddle a handover, and a midpoint test hands the whole span to
    /// whichever turn happens to contain that one instant — including a
    /// sub-second turn the span barely touches. Summing per speaker also means
    /// two short turns by the same speaker on either side of an interjection
    /// still outweigh the interjection.
    static func speakerLabel(for span: TranscribedSpan, in turns: [SpeakerTurn]) -> String {
        guard !turns.isEmpty else { return "Speaker 1" }

        var overlapByLabel: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = min(span.end, turn.end) - max(span.start, turn.start)
            if overlap > 0 { overlapByLabel[turn.speakerLabel, default: 0] += overlap }
        }
        if let best = overlapByLabel.max(by: { lhs, rhs in
            // Ties (identical overlap) resolve to the label appearing first in
            // `turns`, keeping the result deterministic across dictionary
            // iteration orders.
            lhs.value == rhs.value
                ? firstIndex(of: lhs.key, in: turns) > firstIndex(of: rhs.key, in: turns)
                : lhs.value < rhs.value
        }) {
            return best.key
        }

        // Nearest by distance to the turn's range, measured from the midpoint.
        let mid = (span.start + span.end) / 2
        let nearest = turns.min { a, b in
            distance(from: mid, to: a) < distance(from: mid, to: b)
        }
        return nearest?.speakerLabel ?? "Speaker 1"
    }

    private static func firstIndex(of label: String, in turns: [SpeakerTurn]) -> Int {
        turns.firstIndex { $0.speakerLabel == label } ?? Int.max
    }

    static func distance(from time: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }
}

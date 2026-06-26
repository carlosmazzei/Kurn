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

        for span in spans {
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

    /// Pick the speaker whose turn best overlaps the span's midpoint, falling
    /// back to the nearest turn by distance to its range.
    static func speakerLabel(for span: TranscribedSpan, in turns: [SpeakerTurn]) -> String {
        guard !turns.isEmpty else { return "Speaker 1" }
        let mid = (span.start + span.end) / 2

        if let containing = turns.first(where: { mid >= $0.start && mid < $0.end }) {
            return containing.speakerLabel
        }
        // Nearest by distance to the turn's range.
        let nearest = turns.min { a, b in
            distance(from: mid, to: a) < distance(from: mid, to: b)
        }
        return nearest?.speakerLabel ?? "Speaker 1"
    }

    static func distance(from time: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }
}

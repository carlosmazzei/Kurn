//
//  TranscriptChunker.swift
//  Kurn
//
//  Splits a meeting's transcript segments into short, embeddable passages. Pure
//  value-in / value-out (no SwiftData, no embedder), so the windowing is
//  deterministic and unit-testable — mirroring `Pipeline/TranscriptFusion.swift`.
//
//  Passages are a few sentences long: small enough that one embedding vector
//  captures a focused topic (good retrieval precision), large enough to carry
//  context. Each passage keeps absolute meeting timestamps (recording offset
//  already applied) so a search hit can deep-link to the moment it came from.
//

import Foundation

/// One embeddable passage: text plus where it sits in the meeting timeline.
struct TranscriptChunk: Sendable, Equatable {
    var recordingID: UUID
    var text: String
    /// Absolute meeting-relative start/end (recording offset already applied).
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// The speaker who contributed the most text in this passage.
    var speakerLabel: String
}

enum TranscriptChunker {
    /// One recording's transcript plus its offset from the meeting start, so the
    /// chunker can express passage timestamps on a single continuous timeline.
    struct Input: Sendable {
        var recordingID: UUID
        var offset: TimeInterval
        var segments: [TranscriptSegment]
    }

    /// Soft ceiling on a passage's character count. A passage flushes once it
    /// reaches this; a single segment longer than the target becomes its own
    /// (oversized) passage rather than being cut mid-sentence.
    static let targetChars = 500
    /// A passage shorter than this keeps absorbing the next segment even past a
    /// speaker change, so trailing one-word turns don't become their own chunk.
    static let minChars = 200

    /// Build passages across all of a meeting's recordings, in chronological
    /// order. Empty-text segments are skipped; whitespace is collapsed per line.
    static func chunk(_ inputs: [Input]) -> [TranscriptChunk] {
        var chunks: [TranscriptChunk] = []
        for input in inputs {
            chunks.append(contentsOf: chunk(input))
        }
        return chunks
    }

    private static func chunk(_ input: Input) -> [TranscriptChunk] {
        var chunks: [TranscriptChunk] = []
        var current = Accumulator(recordingID: input.recordingID)

        for segment in input.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Flush before adding this segment when the passage is already big
            // enough — at a speaker change if we've cleared the minimum, or at
            // the target size regardless.
            if !current.isEmpty {
                let speakerChanged = segment.speakerLabel != current.lastSpeaker
                let overTarget = current.charCount >= Self.targetChars
                if overTarget || (speakerChanged && current.charCount >= Self.minChars) {
                    chunks.append(current.finish())
                    current = Accumulator(recordingID: input.recordingID)
                }
            }

            current.add(
                text: text,
                speaker: segment.speakerLabel,
                start: segment.startTime + input.offset,
                end: segment.endTime + input.offset
            )
        }

        if !current.isEmpty { chunks.append(current.finish()) }
        return chunks
    }

    /// Mutable builder for one in-progress passage. Tracks the dominant speaker
    /// by how much text each contributed, so a passage's label reflects who
    /// actually held the floor rather than whoever spoke first.
    private struct Accumulator {
        let recordingID: UUID
        private var parts: [String] = []
        private var speakerWeights: [String: Int] = [:]
        private var start: TimeInterval = 0
        private var end: TimeInterval = 0
        private(set) var lastSpeaker: String = ""
        private(set) var charCount = 0

        init(recordingID: UUID) { self.recordingID = recordingID }

        var isEmpty: Bool { parts.isEmpty }

        mutating func add(text: String, speaker: String, start: TimeInterval, end: TimeInterval) {
            if parts.isEmpty { self.start = start }
            self.end = max(self.end, end)
            parts.append(text)
            charCount += text.count + 1
            speakerWeights[speaker, default: 0] += text.count
            lastSpeaker = speaker
        }

        func finish() -> TranscriptChunk {
            let dominant = speakerWeights.max {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }?.key ?? lastSpeaker
            return TranscriptChunk(
                recordingID: recordingID,
                text: parts.joined(separator: " "),
                startTime: start,
                endTime: end,
                speakerLabel: dominant
            )
        }
    }
}

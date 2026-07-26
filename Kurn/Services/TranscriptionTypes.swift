//
//  TranscriptionTypes.swift
//  Kurn
//
//  Provider-agnostic intermediate types produced by the transcription engines
//  (on-device or Whisper) before speaker diarization is layered on top.
//

import Foundation

/// A timed span of recognized text, before speaker attribution.
struct TranscribedSpan: Sendable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Float?
}

/// Provider-neutral word timing used to turn ASR token metadata into the fine
/// spans consumed by speaker diarization.
struct TimedWord: Sendable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

enum TimedWordSpanBuilder {
    static func spans(
        from words: [TimedWord],
        fallbackText: String,
        duration: TimeInterval
    ) -> [TranscribedSpan] {
        let upperBound = duration > 0 && duration.isFinite
            ? duration
            : TimeInterval.greatestFiniteMagnitude

        let timedSpans = words.compactMap { word -> TranscribedSpan? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.start.isFinite, word.end.isFinite else { return nil }

            let start = min(upperBound, max(0, word.start))
            let end = min(upperBound, max(start, word.end))
            guard end > start else { return nil }
            return TranscribedSpan(text: text, start: start, end: end, confidence: nil)
        }

        if !timedSpans.isEmpty {
            return timedSpans
        }

        let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscribedSpan(text: text, start: 0, end: max(0, duration), confidence: nil)]
    }
}

/// The raw output of a transcription engine: ordered spans + detected language.
struct RawTranscript: Sendable {
    var spans: [TranscribedSpan]
    /// BCP-47 (or two-letter) locale string, may be empty if unknown.
    var language: String
}

/// A diarized speaker turn: which speaker spoke during [start, end).
struct SpeakerTurn: Sendable, Hashable {
    var speakerLabel: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A speaker diarization engine. Implementations must never throw — on any
/// failure they should fall back to a single turn covering the whole clip, so
/// `TranscriptionService` always gets usable output.
protocol Diarizing: Sendable {
    func diarize(url: URL) async -> [SpeakerTurn]
}

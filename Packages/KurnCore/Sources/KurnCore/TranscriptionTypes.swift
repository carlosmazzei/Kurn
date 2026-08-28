//
//  TranscriptionTypes.swift
//  KurnCore
//
//  Provider-agnostic intermediate types produced by the transcription engines
//  (on-device or Whisper) before speaker diarization is layered on top.
//

import Foundation

/// A timed span of recognized text, before speaker attribution.
public struct TranscribedSpan: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Provider-neutral word timing used to turn ASR token metadata into the fine
/// spans consumed by speaker diarization.
public struct TimedWord: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum TimedWordSpanBuilder {
    public static func spans(
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
public struct RawTranscript: Sendable {
    public var spans: [TranscribedSpan]
    /// BCP-47 (or two-letter) locale string, may be empty if unknown.
    public var language: String

    public init(spans: [TranscribedSpan], language: String) {
        self.spans = spans
        self.language = language
    }
}

/// A diarized speaker turn: which speaker spoke during [start, end).
public struct SpeakerTurn: Sendable, Hashable {
    public var speakerLabel: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerLabel: String, start: TimeInterval, end: TimeInterval) {
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
    }
}

/// A speaker diarization engine. Implementations must never throw — on any
/// failure they should fall back to a single turn covering the whole clip, so
/// `TranscriptionService` always gets usable output.
public protocol Diarizing: Sendable {
    func diarize(url: URL) async -> [SpeakerTurn]
}

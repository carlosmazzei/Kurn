//
//  AppleSpeechResultAssembly.swift
//  KurnCore
//
//  The engine-independent half of `OnDeviceTranscriber`: what one final
//  SpeechAnalyzer result — its text, its range, and the per-run word timings
//  the `.timeIndexedProgressiveTranscription` preset attaches — becomes in the
//  app's own spans, and how far along the pass is. The adapter only reads the
//  Speech framework's types into these values.
//

import Foundation

public enum AppleSpeechResultAssembly {
    /// How far a word may sit outside its result's range before the timings
    /// are judged to be on another timeline.
    public static let timelineTolerance: TimeInterval = 1

    public struct Assembly: Equatable, Sendable {
        public var spans: [TranscribedSpan]
        /// The result carried word timings that contradicted its own range, so
        /// they were dropped in favour of the result-level span.
        public var rejectedWordTimings: Bool

        public init(spans: [TranscribedSpan], rejectedWordTimings: Bool) {
            self.spans = spans
            self.rejectedWordTimings = rejectedWordTimings
        }
    }

    /// A result's `[start, end)` in seconds, or `nil` when the framework
    /// reported a non-finite time — such a result is skipped, not guessed at.
    public static func resultBounds(
        start: TimeInterval,
        duration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard start.isFinite, duration.isFinite else { return nil }
        return (max(0, start), max(0, start + duration))
    }

    /// One attributed run as a word, or `nil` for a run without usable text
    /// or timing. Runs without a time range never reach this.
    public static func word(text: String, start: TimeInterval, end: TimeInterval) -> TimedWord? {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty, start.isFinite, end.isFinite, end > start else { return nil }
        return TimedWord(text: piece, start: max(0, start), end: max(0, end))
    }

    /// One recognizer result as the spans it should contribute.
    ///
    /// The timeline check is the point of it. `audioTimeRange` is documented on
    /// the same timeline as `result.range`, and if a future SDK ever reported it
    /// relative to the result instead, every word would land near zero: the
    /// transcript would still read correctly, the timestamps would be silently
    /// wrong, and speaker attribution would collapse onto whoever spoke first.
    /// Rather than trust it, check that the words land where the result says
    /// they should, and fall back to the result-level span when they don't.
    public static func assemble(
        words: [TimedWord],
        text: String,
        resultStart: TimeInterval,
        resultEnd: TimeInterval,
        duration: TimeInterval
    ) -> Assembly {
        let wholeResult = [TranscribedSpan(text: text, start: resultStart, end: resultEnd)]
        guard let first = words.first, let last = words.last else {
            return Assembly(spans: wholeResult, rejectedWordTimings: false)
        }
        guard first.start >= resultStart - timelineTolerance,
              last.end <= resultEnd + timelineTolerance else {
            return Assembly(spans: wholeResult, rejectedWordTimings: true)
        }
        let built = TimedWordSpanBuilder.spans(from: words, fallbackText: "", duration: duration)
        return Assembly(spans: built.isEmpty ? wholeResult : built, rejectedWordTimings: false)
    }

    /// Progress after a result ending at `resultEnd`, held below 1 until the
    /// analyzer finishes; `nil` when the clip length is unknown.
    public static func progress(resultEnd: TimeInterval, duration: TimeInterval) -> Double? {
        guard duration > 0 else { return nil }
        return min(0.99, max(0, resultEnd / duration))
    }

    /// The finished transcript's spans in time order, or `nil` when nothing
    /// was recognised — which the caller reports as "no speech detected".
    public static func finished(_ spans: [TranscribedSpan]) -> [TranscribedSpan]? {
        let sorted = spans.sorted { $0.start < $1.start }
        return sorted.isEmpty ? nil : sorted
    }
}

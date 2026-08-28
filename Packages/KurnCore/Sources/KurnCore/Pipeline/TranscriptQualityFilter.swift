//
//  TranscriptQualityFilter.swift
//  KurnCore
//
//  Drops the segments a Whisper decoder produced without hearing them.
//
//  Whisper's failure mode is not a wrong word, it is a fluent invention: over
//  silence, music or noise it emits a plausible sentence — often the same one
//  over and over — with no signal in the text that anything went wrong. The
//  decoder does know, though, and reports it per segment. The production
//  consensus is to act on three of those numbers, and this is where that happens:
//
//  - `noSpeechProb` — the model's own probability that the window is silence.
//  - `averageLogProb` — how confident the decode was, in nats per token.
//  - `compressionRatio` — how compressible the text is; a loop compresses far
//    better than prose, so a high ratio means the decoder was repeating itself.
//
//  The two rules below are Whisper's own, thresholds included, and matter in the
//  order they are written: a *confident* decode overrides a high no-speech
//  probability, which is why the silence rule is a conjunction rather than a
//  `noSpeechProb` test alone. Being wrong here is asymmetric — a dropped real
//  sentence is a hole the user can hear on playback, an invented one is a lie
//  they cannot detect — so every threshold errs towards keeping.
//
//  `isRepetitionLoop` is ours rather than Whisper's, and exists because
//  `compressionRatio` is a cloud-only field: whisper.cpp reports no equivalent,
//  so on device the loop has to be found in the text.
//

import Foundation

/// Per-segment decoder confidence signals. Every field is optional because the
/// engines report different subsets — the cloud API returns all three,
/// whisper.cpp two, and the others none.
public struct SpanQuality: Sendable, Hashable {
    public var averageLogProb: Double?
    public var noSpeechProb: Double?
    public var compressionRatio: Double?

    public static let unknown = SpanQuality()

    public init(averageLogProb: Double? = nil, noSpeechProb: Double? = nil, compressionRatio: Double? = nil) {
        self.averageLogProb = averageLogProb
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
    }

    /// `averageLogProb` is a mean log-probability per token, so exponentiating it
    /// gives the per-token probability the decoder assigned — a 0…1 confidence in
    /// the same units `TranscribedSpan.confidence` is documented in.
    public var confidence: Float? {
        guard let averageLogProb, averageLogProb.isFinite else { return nil }
        return Float(min(1, max(0, exp(averageLogProb))))
    }
}

public enum TranscriptQualityFilter {

    /// Forwards this filter's diagnostics to the app's leveled logger.
    /// `nonisolated(unsafe)`, matching `AppLog.minimumLevel`'s own pattern in
    /// the app — required because Swift 6's strict concurrency mode rejects a
    /// plain mutable `static var` even when its value type is `Sendable`.
    /// Written exactly once, at startup, before any concurrent read. `os` is
    /// unavailable on Linux, so this keeps that dependency out of KurnCore
    /// while still routing diagnostics through `AppLog` in the app.
    public nonisolated(unsafe) static var logHandler: (@Sendable (String) -> Void)?

    // MARK: - Thresholds

    /// Below this, the decoder was guessing. Whisper's own `logprob_threshold`.
    public static let minimumAverageLogProb: Double = -1.0
    /// Above this, the model thinks the window holds no speech. Whisper's own
    /// `no_speech_threshold`.
    public static let maximumNoSpeechProb: Double = 0.6
    /// Above this, the text compresses too well to be prose. Whisper's own
    /// `compression_ratio_threshold`.
    public static let maximumCompressionRatio: Double = 2.4

    /// Why a segment was discarded. Carried out of the decision so the caller can
    /// log the distribution rather than a bare count.
    public enum Rejection: String, Sendable {
        case silence
        case compression
        case repetition
    }

    /// A span paired with the quality signals its engine reported for it.
    public struct ScoredSpan: Sendable {
        public var span: TranscribedSpan
        public var quality: SpanQuality
        /// Word timings *inside* this segment, when the engine reports them.
        ///
        /// They ride along with the segment rather than being filtered in their
        /// own right because the quality signals are per segment: a hallucinated
        /// sentence has to be dropped whole, and its words carry no evidence of
        /// their own. A surviving segment is then emitted one span per word.
        public var words: [TimedWord] = []

        public init(span: TranscribedSpan, quality: SpanQuality, words: [TimedWord] = []) {
            self.span = span
            self.quality = quality
            self.words = words
        }
    }

    // MARK: - Decision

    /// Whether this segment should be discarded, and why. Pure.
    public static func rejection(text: String, quality: SpanQuality) -> Rejection? {
        // Silence. Both fields are required: a missing one is not evidence, and
        // guessing from `noSpeechProb` alone would drop quiet real speech.
        if let noSpeech = quality.noSpeechProb,
           let logProb = quality.averageLogProb,
           noSpeech.isFinite, logProb.isFinite,
           noSpeech > maximumNoSpeechProb,
           logProb < minimumAverageLogProb {
            return .silence
        }

        if let ratio = quality.compressionRatio, ratio.isFinite, ratio > maximumCompressionRatio {
            return .compression
        }

        if isRepetitionLoop(text) {
            return .repetition
        }

        return nil
    }

    /// Filter `scored`, keeping the spans that survive and stamping each with the
    /// confidence its quality implies. `engine` only labels the log line.
    ///
    /// A survivor carrying word timings comes back as one span per word rather
    /// than one per segment. That is what lets `TranscriptFusion` attribute a
    /// handover mid-sentence to the right speaker instead of estimating the split
    /// from turn durations.
    public static func keeping(_ scored: [ScoredSpan], engine: String) -> [TranscribedSpan] {
        var kept: [TranscribedSpan] = []
        var survivors = 0
        var rejections: [Rejection: Int] = [:]

        for item in scored {
            if let reason = rejection(text: item.span.text, quality: item.quality) {
                rejections[reason, default: 0] += 1
                logHandler?("\(engine): dropped \(reason.rawValue) span at \(item.span.start)s")
                continue
            }
            survivors += 1
            kept.append(contentsOf: expand(item))
        }

        if !rejections.isEmpty {
            let summary = rejections
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }
                .joined(separator: " ")
            logHandler?("\(engine): discarded \(scored.count - survivors)/\(scored.count) low-quality span(s) [\(summary)]")
        }
        return kept
    }

    /// One surviving segment as the spans it should contribute: its words when
    /// the engine timed them, otherwise the segment itself. Either way the
    /// segment's confidence is what gets stamped — a per-word confidence is not
    /// something any of these engines reports.
    private static func expand(_ item: ScoredSpan) -> [TranscribedSpan] {
        let confidence = item.quality.confidence
        // Empty `fallbackText` on purpose: the builder's own fallback is a span
        // over `0...duration`, which for a segment starting at 14:32 would be
        // wrong in a way nothing downstream could detect. When it finds no usable
        // word, the segment span below is the correct answer.
        let words = TimedWordSpanBuilder.spans(
            from: item.words,
            fallbackText: "",
            duration: item.span.end
        )
        guard !words.isEmpty else {
            var span = item.span
            span.confidence = confidence
            return [span]
        }
        return words.map {
            var span = $0
            span.confidence = confidence
            return span
        }
    }

    // MARK: - Repetition

    /// Fewer tokens than this and a repeat is a figure of speech, not a loop.
    private static let minimumTokens = 6
    /// A cycle has to *dominate* the segment. Without this, six repeated words at
    /// the end of a long, good sentence would take the whole sentence with them.
    private static let minimumCoverage = 0.6
    /// One word repeated needs more evidence than a phrase repeated: "no, no, no"
    /// is speech, "Amara.org Amara.org Amara.org" is not.
    private static let minimumUnigramRepeats = 6
    private static let minimumPhraseRepeats = 3
    /// Cap the search: a longer cycle than this inside one segment is not the
    /// failure mode being looked for, and the scan is O(period × tokens).
    private static let maximumPeriod = 24

    /// Whether `text` is a decoder loop: one cycle of tokens repeated enough times
    /// to cover most of the segment.
    ///
    /// Deliberately blind to *what* is repeated — a phrase blocklist would need
    /// maintaining in seven languages and would still miss the next one. The cost
    /// is that genuinely cyclic speech ("one two three, one two three, one two
    /// three") reads as a loop; that is rarer in a meeting than the hallucination
    /// is, and the coverage floor keeps it to segments that are *nothing but* the
    /// cycle.
    public static func isRepetitionLoop(_ text: String) -> Bool {
        let units = tokens(in: text)
        guard units.count >= minimumTokens else { return false }

        let upperBound = min(units.count / 2, maximumPeriod)
        guard upperBound >= 1 else { return false }

        for period in 1...upperBound {
            let repeats = maximumRepeats(ofPeriod: period, in: units)
            let enough = period == 1
                ? repeats >= minimumUnigramRepeats
                : repeats >= minimumPhraseRepeats
            guard enough else { continue }
            let covered = period * repeats
            if Double(covered) >= Double(units.count) * minimumCoverage {
                return true
            }
        }
        return false
    }

    /// Longest run of `units[i] == units[i + period]`, expressed as a repeat
    /// count: a cycle of length `period` repeated `n` times matches for
    /// `period × (n - 1)` consecutive positions.
    private static func maximumRepeats(ofPeriod period: Int, in units: [String]) -> Int {
        var run = 0
        var longest = 0
        for index in 0..<(units.count - period) {
            if units[index] == units[index + period] {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest / period + 1
    }

    /// Split into comparable units, case- and punctuation-insensitive.
    ///
    /// Scripts written without spaces (Chinese, Japanese) come back from Whisper
    /// as one long "word", where whitespace tokenization would find nothing to
    /// compare. Those fall back to per-character units, which is the right
    /// granularity for the same loop in those languages.
    private static func tokens(in text: String) -> [String] {
        let lowered = text.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2, (words.map(\.count).max() ?? 0) <= 24 {
            return words.map(String.init)
        }
        return lowered.filter { $0.isLetter || $0.isNumber }.map(String.init)
    }
}

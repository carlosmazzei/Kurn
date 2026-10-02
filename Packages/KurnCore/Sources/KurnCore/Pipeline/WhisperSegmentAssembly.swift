//
//  WhisperSegmentAssembly.swift
//  KurnCore
//
//  Turns what whisper.cpp reports about one decoded segment — its text, its
//  centisecond bounds, and its text tokens — into the values the rest of the
//  pipeline consumes. Kept apart from `WhisperCppTranscriber`, which only
//  reads those raw values out of the C context, so every decision here runs
//  on Linux without a model.
//

import Foundation

/// One text token of a decoded segment, as whisper.cpp reports it. Control and
/// timestamp tokens are filtered out by the caller before they get here.
public struct WhisperDecodedToken: Sendable, Hashable {
    /// The SentencePiece piece, including its leading space when it opens a word.
    public var piece: String
    /// Bounds in centiseconds from the start of the chunk, whisper's own unit.
    public var startCentiseconds: Int64
    public var endCentiseconds: Int64
    /// The decoder's probability for this token.
    public var probability: Float

    public init(piece: String, startCentiseconds: Int64, endCentiseconds: Int64, probability: Float) {
        self.piece = piece
        self.startCentiseconds = startCentiseconds
        self.endCentiseconds = endCentiseconds
        self.probability = probability
    }
}

public enum WhisperSegmentAssembly {

    /// whisper.cpp reports every bound in centiseconds.
    public static func seconds(fromCentiseconds value: Int64) -> TimeInterval {
        Double(value) / 100
    }

    /// Word timings for one segment, aggregated from its sub-word tokens.
    ///
    /// Whisper emits SentencePiece pieces, not words: "orçamento" can arrive as
    /// "or", "ça", "mento". A piece that begins with whitespace opens a new word
    /// and every piece after it extends that word — the same rule the tokenizer
    /// used to produce them. Whitespace-only pieces carry no text and are skipped.
    public static func words(from tokens: [WhisperDecodedToken]) -> [TimedWord] {
        var words: [TimedWord] = []
        for token in tokens {
            let text = token.piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = seconds(fromCentiseconds: token.startCentiseconds)
            let end = seconds(fromCentiseconds: token.endCentiseconds)
            if token.piece.first?.isWhitespace == true || words.isEmpty {
                words.append(TimedWord(text: text, start: start, end: max(start, end)))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = max(words[words.count - 1].end, end)
            }
        }
        return words
    }

    /// The decoder's confidence in one segment.
    ///
    /// Whisper's `avg_logprob` is the mean log-probability over *text* tokens;
    /// probabilities are floored at 1e-10 so a zero cannot make it -∞, and a
    /// non-finite one is ignored. whisper.cpp has no `compression_ratio`, so that
    /// field stays `nil` and the filter's repetition test catches loops instead.
    public static func quality(tokenProbabilities: [Float], noSpeechProbability: Float) -> SpanQuality {
        var total = 0.0
        var count = 0
        for probability in tokenProbabilities.map(Double.init) where probability.isFinite {
            total += log(max(probability, 1e-10))
            count += 1
        }
        let noSpeech = Double(noSpeechProbability)
        return SpanQuality(
            averageLogProb: count > 0 ? total / Double(count) : nil,
            noSpeechProb: noSpeech.isFinite ? noSpeech : nil,
            compressionRatio: nil
        )
    }

    /// One segment ready for `TranscriptQualityFilter`, or `nil` when its text is
    /// blank. An end before the start is clamped to the start.
    public static func scoredSpan(
        text: String,
        startCentiseconds: Int64,
        endCentiseconds: Int64,
        tokens: [WhisperDecodedToken],
        noSpeechProbability: Float
    ) -> TranscriptQualityFilter.ScoredSpan? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let start = seconds(fromCentiseconds: startCentiseconds)
        let end = seconds(fromCentiseconds: endCentiseconds)
        return TranscriptQualityFilter.ScoredSpan(
            span: TranscribedSpan(text: trimmed, start: start, end: max(start, end), confidence: nil),
            quality: quality(tokenProbabilities: tokens.map(\.probability), noSpeechProbability: noSpeechProbability),
            words: words(from: tokens)
        )
    }

    /// Inference threads: every core but one, which the UI keeps for rendering
    /// the progress bar. whisper saturates whatever it is given.
    public static func inferenceThreadCount(activeProcessors: Int) -> Int {
        max(1, activeProcessors - 1)
    }
}

/// Maps progress inside one chunk onto the whole run, so a single long chunk
/// still advances the bar instead of jumping once when it finishes.
public enum ChunkedProgress {
    public static func overall(chunkIndex: Int, fraction: Double, total: Int) -> (fraction: Double, completedChunks: Int) {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        let safeTotal = max(1, total)
        return ((Double(chunkIndex) + clamped) / Double(safeTotal), min(safeTotal, chunkIndex + 1))
    }
}

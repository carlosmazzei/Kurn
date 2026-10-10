//
//  ContextBudget.swift
//  KurnCore
//
//  How much text one LLM request may carry, decided per model instead of
//  assumed for every model at once. Summaries, per-meeting chat, the library
//  synthesis and generated documents all choose between one request over the
//  whole input and a map-reduce over blocks; that choice used to be a fixed
//  80k-character threshold sized for the smallest context window any vendor
//  had, so a two-hour meeting went through lossy staged notes on a model that
//  could have read the transcript whole.
//
//  The budget is in tokens, estimated from the text itself, because a
//  character threshold is wrong by a different factor per script: 80k
//  characters is ~20k tokens of English and ~80k tokens of Chinese.
//

import Foundation

/// Input-token allowance for one request, plus the block size the map stage
/// uses when the input does not fit.
public struct ContextBudget: Sendable, Equatable {
    /// Estimated input tokens one single-pass request may carry, excluding
    /// the output reservation and prompt framing already subtracted.
    public let inputTokens: Int
    /// Estimated input tokens per map-stage block when the input overflows.
    /// Smaller than `inputTokens` because a block is wrapped in extra framing.
    public let mapBlockTokens: Int

    public init(inputTokens: Int, mapBlockTokens: Int) {
        self.inputTokens = max(1, inputTokens)
        self.mapBlockTokens = max(1, min(mapBlockTokens, inputTokens))
    }

    /// Whether `text` fits a single request.
    public func fits(_ text: String) -> Bool {
        TokenEstimate.tokens(in: text) <= inputTokens
    }

    /// Map-stage block size in characters for `text`, converting
    /// `mapBlockTokens` with the text's own characters-per-token ratio so a
    /// block of Chinese is as many tokens as a block of English.
    public func mapBlockChars(for text: String) -> Int {
        max(1, Int((Double(mapBlockTokens) * TokenEstimate.charactersPerToken(in: text)).rounded()))
    }

    // MARK: - Budgets

    /// Share of the context window treated as usable. Token estimates are
    /// approximate and vendors count framing (role markers, JSON mode) we
    /// cannot see, so the full window is never planned against.
    static let windowSafetyFraction = 0.8
    /// Tokens reserved for the system prompt, request framing and a modest
    /// chat history on top of the output reservation.
    static let promptOverheadTokens = 4_000
    /// Upper bound on a single request regardless of window. Answers degrade
    /// on very long inputs well before a 1M-token window is full, and ~100k
    /// tokens already holds about seven hours of meeting transcript.
    static let practicalCapTokens = 100_000
    /// Floor for a model whose window is smaller than the output reservation
    /// itself; such a model will likely reject the request anyway, but the
    /// budget must stay positive so splitting still terminates.
    static let minimumInputTokens = 1_000

    /// Budget for a model whose context window is known.
    /// - Parameters:
    ///   - contextWindowTokens: total tokens the model accepts per request.
    ///   - reservedOutputTokens: the request's output allowance, which most
    ///     vendors count against the same window.
    public static func forContextWindow(_ contextWindowTokens: Int, reservedOutputTokens: Int) -> ContextBudget {
        let usable = Int(Double(contextWindowTokens) * windowSafetyFraction)
            - reservedOutputTokens - promptOverheadTokens
        let input = min(practicalCapTokens, max(minimumInputTokens, usable))
        return ContextBudget(inputTokens: input, mapBlockTokens: input * 3 / 4)
    }

    /// Budget for a model whose window is unknown (custom endpoints, new
    /// model names), and the one a request falls back to after a provider
    /// rejected an input as too long. Matches the fixed thresholds every
    /// cloud model used before budgets were per model (80k/60k characters of
    /// Latin-script text).
    public static let conservative = ContextBudget(inputTokens: 23_000, mapBlockTokens: 17_000)

    /// Apple's on-device model shares ~4k tokens between instructions, input
    /// and output (iOS 26). Matches the previous 6k/5k-character thresholds
    /// for Latin-script text; conservative first-cut figures, not measured.
    public static let onDevice = ContextBudget(inputTokens: 1_700, mapBlockTokens: 1_400)
}

/// Rough, deliberately pessimistic token count for prompt planning. Not a
/// tokenizer: it only has to keep a request inside a model's window, never
/// to match a vendor's bill.
public enum TokenEstimate {
    /// Latin, Greek and Cyrillic text including the transcript's
    /// `[mm:ss] Speaker N:` framing, which tokenizes worse than prose.
    static let charactersPerTokenAlphabetic = 3.5
    /// Scripts without spaces between words (Han, kana, Hangul, Thai…) cost
    /// about one token per character in current tokenizers, often less;
    /// counting one keeps the estimate on the safe side.
    static let charactersPerTokenIdeographic = 1.0
    /// Everything else (Arabic, Hebrew, Devanagari, emoji…), which current
    /// tokenizers split more finely than Latin.
    static let charactersPerTokenOther = 2.0

    public static func tokens(in text: String) -> Int {
        Int(estimate(text).rounded(.up))
    }

    /// Characters (grapheme clusters, matching `String.count`, which the
    /// block splitters measure in) per estimated token in `text`.
    public static func charactersPerToken(in text: String) -> Double {
        let tokens = estimate(text)
        guard tokens > 0 else { return charactersPerTokenAlphabetic }
        return Double(text.count) / tokens
    }

    private static func estimate(_ text: String) -> Double {
        var alphabetic = 0
        var ideographic = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 0x0530 {
                alphabetic += 1
            } else if isIdeographic(scalar) {
                ideographic += 1
            } else {
                other += 1
            }
        }
        return Double(alphabetic) / charactersPerTokenAlphabetic
            + Double(ideographic) / charactersPerTokenIdeographic
            + Double(other) / charactersPerTokenOther
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF,   // Thai, Lao
             0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x9FFF,   // CJK radicals, punctuation, kana, unified ideographs
             0xA960...0xA97F,   // Hangul Jamo Extended-A
             0xAC00...0xD7FF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF,   // Half/full-width forms
             0x20000...0x3FFFF: // CJK extensions B…H
            return true
        default:
            return false
        }
    }
}

extension AppError {
    /// Whether a provider rejected the request because its input was too long
    /// for the model — the signal to retry the same work on the staged path
    /// with `ContextBudget.conservative`, rather than surface the error. A
    /// budget can be wrong (an outdated table entry, a custom endpoint, a
    /// per-minute token limit lower than the window), so this check is what
    /// makes planning against a large window safe.
    public var isContextOverflow: Bool {
        guard case .apiError(let status, let message) = self else { return false }
        if status == 413 { return true }
        guard [400, 422].contains(status) else { return false }
        let text = message.lowercased()
        return Self.contextOverflowMarkers.contains { text.contains($0) }
    }

    /// Phrases vendors use for an over-long input: OpenAI and compatible
    /// servers ("maximum context length", `context_length_exceeded`),
    /// Anthropic ("prompt is too long"), Gemini ("input token count …
    /// exceeds the maximum number of tokens"), Groq ("reduce the length of
    /// the messages").
    static let contextOverflowMarkers = [
        "context length",
        "context_length",
        "context window",
        "prompt is too long",
        "input token count",
        "maximum number of tokens",
        "too many tokens",
        "reduce the length"
    ]
}

//
//  ContextBudget.swift
//  Kurn application
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

import AgentHarness
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

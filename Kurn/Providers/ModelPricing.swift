//
//  ModelPricing.swift
//  Kurn
//
//  Approximate USD cost per token for chat models this app's cloud providers
//  commonly serve, so the chat UI can show a rough per-answer cost alongside
//  the token counts a provider's own API reports (`TokenUsage`). Deliberately
//  narrow and best-effort: vendor pricing changes over time and varies by
//  tier/region, and this table cannot track that — a model it doesn't
//  recognize (a custom endpoint, a brand-new release) shows token counts
//  with no cost rather than a guess, which is why every call site treats a
//  `nil` result as "no estimate available", never as zero.
//

import Foundation

enum ModelPricing {
    /// USD per single token. Vendors quote per 1M tokens; dividing once here
    /// keeps every call site a plain multiplication.
    private struct Rate {
        let input: Double
        let output: Double
    }

    /// Matched by case-insensitive prefix against the configured model
    /// string (e.g. "gpt-4o-mini-2024-07-18" matches the "gpt-4o-mini"
    /// entry), longest prefix wins so a specific entry isn't shadowed by a
    /// shorter family match ("gpt-4o" vs "gpt-4o-mini"). Figures are
    /// approximate list prices as of this file's writing and will drift —
    /// update them when a provider's published pricing changes materially,
    /// but treat staleness as expected, not a bug to chase to zero.
    private static let rates: [(prefix: String, rate: Rate)] = [
        ("gpt-4o-mini", Rate(input: 0.15e-6, output: 0.6e-6)),
        ("gpt-4o", Rate(input: 2.5e-6, output: 10e-6)),
        ("gpt-5.4", Rate(input: 1.25e-6, output: 10e-6)),
        ("gpt-5", Rate(input: 1.25e-6, output: 10e-6)),
        ("claude-3-5-haiku", Rate(input: 0.8e-6, output: 4e-6)),
        ("claude-3-5-sonnet", Rate(input: 3e-6, output: 15e-6)),
        ("claude-opus", Rate(input: 15e-6, output: 75e-6)),
        ("claude", Rate(input: 3e-6, output: 15e-6)),
        ("gemini-1.5-flash", Rate(input: 0.075e-6, output: 0.3e-6)),
        ("gemini-1.5-pro", Rate(input: 1.25e-6, output: 5e-6)),
        ("gemini", Rate(input: 1.25e-6, output: 5e-6)),
        ("llama-3.3-70b", Rate(input: 0.59e-6, output: 0.79e-6)),
        ("llama-3.1-8b", Rate(input: 0.05e-6, output: 0.08e-6)),
        ("llama", Rate(input: 0.59e-6, output: 0.79e-6))
    ]

    /// Estimated USD cost of `usage` under `model`, or `nil` when the model
    /// isn't recognized.
    static func estimatedCostUSD(model: String, usage: TokenUsage) -> Double? {
        let lowerModel = model.lowercased()
        guard let rate = rates
            .filter({ lowerModel.hasPrefix($0.prefix) })
            .max(by: { $0.prefix.count < $1.prefix.count })?
            .rate
        else { return nil }
        return Double(usage.promptTokens) * rate.input + Double(usage.completionTokens) * rate.output
    }
}

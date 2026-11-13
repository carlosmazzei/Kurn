//
//  ModelPricingTests.swift
//  KurnTests
//
//  Pure logic, no network: prefix matching (including the "longest prefix
//  wins" rule that keeps a specific model from being shadowed by a shorter
//  family entry) and the "unrecognized model reports no estimate" contract.
//

import AgentHarness
import Testing
@testable import Kurn

struct ModelPricingTests {

    @Test func knownModelReturnsAPositiveEstimate() {
        let usage = TokenUsage(promptTokens: 1_000_000, completionTokens: 1_000_000)
        let cost = ModelPricing.estimatedCostUSD(model: "gpt-4o", usage: usage)
        #expect(cost != nil)
        #expect(cost! > 0)
    }

    @Test func unrecognizedModelReturnsNilRatherThanAGuess() {
        let usage = TokenUsage(promptTokens: 100, completionTokens: 100)
        #expect(ModelPricing.estimatedCostUSD(model: "some-future-model-xyz", usage: usage) == nil)
    }

    @Test func matchIsCaseInsensitiveAndPrefixBased() {
        let usage = TokenUsage(promptTokens: 1_000, completionTokens: 1_000)
        let lower = ModelPricing.estimatedCostUSD(model: "gpt-4o-mini-2024-07-18", usage: usage)
        let upper = ModelPricing.estimatedCostUSD(model: "GPT-4O-MINI-2024-07-18", usage: usage)
        #expect(lower != nil)
        #expect(lower == upper)
    }

    /// "gpt-4o-mini" must not be priced as the shorter "gpt-4o" entry — the
    /// longest matching prefix has to win, not table order.
    @Test func longestPrefixWinsOverAShorterFamilyEntry() {
        let usage = TokenUsage(promptTokens: 1_000_000, completionTokens: 1_000_000)
        let miniCost = ModelPricing.estimatedCostUSD(model: "gpt-4o-mini", usage: usage)
        let fullCost = ModelPricing.estimatedCostUSD(model: "gpt-4o", usage: usage)
        #expect(miniCost != nil)
        #expect(fullCost != nil)
        #expect(miniCost! < fullCost!)
    }

    @Test func costScalesWithTokenCount() {
        let single = TokenUsage(promptTokens: 1_000, completionTokens: 0)
        let double = TokenUsage(promptTokens: 2_000, completionTokens: 0)
        let singleCost = try? #require(ModelPricing.estimatedCostUSD(model: "claude-3-5-sonnet", usage: single))
        let doubleCost = try? #require(ModelPricing.estimatedCostUSD(model: "claude-3-5-sonnet", usage: double))
        #expect(doubleCost == singleCost.map { $0 * 2 })
    }

    /// Cached input is priced at the cache's own rate: a read at the vendor's discount, an
    /// Anthropic cache write at its surcharge, and the rest of the input at the full rate.
    @Test func cacheReadsAndWritesArePricedAtTheirOwnRates() throws {
        let plain = try #require(ModelPricing.estimatedCostUSD(model: "claude-3-5-sonnet",
                                                               usage: AgentUsage(inputTokens: 1_000_000, outputTokens: 0)))
        let cached = try #require(ModelPricing.estimatedCostUSD(model: "claude-3-5-sonnet", usage: AgentUsage(
            inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 600_000, cacheWriteTokens: 200_000)))
        // 200k uncached at $3/M, 600k read at 10% and 200k written at 125%.
        #expect(abs(plain - 3) < 1e-9)
        #expect(abs(cached - (0.6 + 0.18 + 0.75)) < 1e-9)

        // OpenAI and Gemini discount reads and charge no write surcharge.
        let gpt = try #require(ModelPricing.estimatedCostUSD(model: "gpt-5", usage: AgentUsage(
            inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 1_000_000)))
        #expect(abs(gpt - 0.125) < 1e-9)
        // A model without cache pricing charges cached input as input, and counts never exceed it.
        let llama = try #require(ModelPricing.estimatedCostUSD(model: "llama-3.3-70b", usage: AgentUsage(
            inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 2_000_000)))
        #expect(abs(llama - 0.59) < 1e-9)
        // The summary's plain token count is the same price as an uncached agent request.
        #expect(ModelPricing.estimatedCostUSD(model: "claude-3-5-sonnet", usage: TokenUsage(promptTokens: 1_000_000, completionTokens: 0)) == plain)
    }
}

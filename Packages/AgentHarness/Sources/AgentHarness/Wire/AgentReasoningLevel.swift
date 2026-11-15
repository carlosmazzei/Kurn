import Foundation

/// How much a model should reason before it answers, chosen by the host and mapped per vendor:
/// OpenAI's `reasoning.effort` (with a visible `summary` on Responses), Anthropic's extended
/// thinking budget and Gemini's `thinkingConfig` (with `includeThoughts`). Nil leaves the vendor's
/// default, and summary requests never carry it.
public enum AgentReasoningLevel: String, Codable, Sendable, CaseIterable {
    case low, medium, high

    /// Anthropic and Gemini take a token budget instead of a named effort.
    public var thinkingBudget: Int {
        switch self {
        case .low: 2_048
        case .medium: 8_192
        case .high: 24_576
        }
    }

    /// Anthropic's smallest accepted thinking budget.
    public static let minimumThinkingBudget = 1_024

    /// The budget a request with `maxOutputTokens` can carry: below the output limit (Anthropic
    /// counts thinking inside it) and at least the minimum; nil when the limit leaves no room.
    public func thinkingBudget(maxOutputTokens: Int) -> Int? {
        let budget = min(thinkingBudget, maxOutputTokens - 1)
        return budget >= Self.minimumThinkingBudget ? budget : nil
    }
}

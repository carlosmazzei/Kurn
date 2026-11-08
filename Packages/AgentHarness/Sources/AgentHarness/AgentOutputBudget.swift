import Foundation

/// Per-run output allowance. Explicit caller budgets stay fixed. Automatic budgets leave at
/// least three quarters of the context for input and never invent a provider output capacity.
struct AgentOutputBudget: Sendable {
    private(set) var tokens: Int
    let ceiling: Int
    private(set) var retries = 0

    init(requested: Int?, policy: AgentContextPolicy) {
        if let requested {
            tokens = max(1, min(requested, policy.maxOutputTokens ?? requested))
            ceiling = tokens
        } else {
            ceiling = max(1, min(65_536, policy.maxOutputTokens ?? 4_096, policy.contextWindow / 4))
            tokens = min(32_768, ceiling)
        }
    }

    /// A limited response has not executed any tools yet. Only retry an empty, unseen reply;
    /// never replay partial visible text. One increase per run also bounds extra requests/cost.
    mutating func recover(_ response: AgentTurnResponse, streamed: Bool, state: AgentRunState,
                          costReached: Bool, trace: AgentTraceEmitter) -> Bool {
        let allowed = !costReached && state.turns < state.allowedTurns
        let metrics: [AgentDiagnostic.Metric: Int] = [
            .maxOutputTokens: tokens, .hardMaxOutputTokens: ceiling, .outputRetries: retries,
            .visibleTextScalars: response.text.unicodeScalars.count, .streamedText: streamed ? 1 : 0,
            .costLimitReached: costReached ? 1 : 0, .turnIndex: state.turns, .maxTurns: state.allowedTurns
        ]
        guard response.text.isEmpty, !streamed, retries == 0, tokens < ceiling, allowed else {
            trace.record(.outputBudgetExtensionDenied, metrics: metrics, reason: .outputLimit)
            return false
        }
        tokens = min(ceiling, tokens * 2)
        retries += 1
        var extended = metrics
        extended[.previousMaxOutputTokens] = metrics[.maxOutputTokens]
        extended[.maxOutputTokens] = tokens
        extended[.outputRetries] = retries
        trace.record(.outputBudgetExtended, metrics: extended, reason: .outputLimit)
        return true
    }
}

extension AgentTurnResponse {
    /// Fixed numeric vocabulary only: provider text, arguments and reasoning content never enter logs.
    var diagnosticMetrics: [AgentDiagnostic.Metric: Int] {
        var metrics: [AgentDiagnostic.Metric: Int] = [
            .visibleTextScalars: text.unicodeScalars.count, .returnedToolCalls: toolCalls.count,
            .discardedToolCalls: discardedToolCalls + (stopReason == .maxTokens ? toolCalls.count : 0),
            .outputLimited: stopReason == .maxTokens ? 1 : 0, .usageReported: usage == nil ? 0 : 1
        ]
        if let usage {
            metrics[.inputTokens] = usage.inputTokens
            metrics[.outputTokens] = usage.outputTokens
            metrics[.reasoningTokens] = usage.reasoningTokens
        }
        return metrics
    }
}

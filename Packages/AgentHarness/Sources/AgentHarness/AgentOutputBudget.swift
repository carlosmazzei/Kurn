import Foundation

/// Dynamic output headroom, matching pi's clampMaxTokensToContext at f064465.
/// Capacities still come from the host's resolver; an unknown capacity uses an explicit fallback.
struct AgentOutputBudget: Sendable {
    private(set) var tokens: Int
    let ceiling: Int
    let contextWindow: Int
    let isFallback: Bool
    private let allowsRecovery: Bool
    private(set) var retries = 0
    private(set) var inputTokens = 0
    private(set) var safetyTokens = 4_096
    private(set) var availableTokens = 0
    private(set) var relaxedSafety = false

    init(requested: Int?, policy: AgentContextPolicy) {
        ceiling = max(1, min(requested ?? policy.maxOutputTokens ?? 4_096, policy.maxOutputTokens ?? .max))
        tokens = ceiling
        contextWindow = policy.contextWindow
        isFallback = requested == nil && policy.maxOutputTokens == nil
        allowsRecovery = requested == nil
    }

    mutating func fit(inputTokens: Int) {
        self.inputTokens = max(0, inputTokens)
        let proportional = (Double(self.inputTokens) * 0.15).rounded(.up)
        safetyTokens = proportional >= Double(Int.max) ? .max : max(4_096, Int(proportional))
        // Saturating subtraction also accepts deliberately adversarial estimator values.
        let headroom = contextWindow - self.inputTokens
        relaxedSafety = headroom < safetyTokens || headroom - safetyTokens < 32_768
        if relaxedSafety { safetyTokens = 4_096 }
        availableTokens = headroom < Int.min + safetyTokens ? .min : headroom - safetyTokens
        let room = relaxedSafety ? min(32_768, availableTokens) : availableTokens
        tokens = min(ceiling, max(1, room))
    }

    var diagnosticMetrics: [AgentDiagnostic.Metric: Int] {
        [.contextTokens: inputTokens, .maxOutputTokens: tokens, .hardMaxOutputTokens: ceiling,
         .contextSafetyTokens: safetyTokens, .contextSafetyRelaxed: relaxedSafety ? 1 : 0,
         .availableOutputTokens: availableTokens, .outputCapacityFallback: isFallback ? 1 : 0,
         .outputRetries: retries]
    }

    /// Keep the app's visibility/turn/cost guards. Retry an early length stop only after one
    /// successful forced compaction; never double the desired capacity or replay visible text.
    func canRecover(_ response: AgentTurnResponse, streamed: Bool, state: AgentRunState, costReached: Bool) -> Bool {
        allowsRecovery && response.text.isEmpty && !streamed && retries == 0
            && !costReached && state.turns < state.allowedTurns
            && response.usage.map { $0.outputTokens < ceiling } == true
    }

    func recoveryMetrics(_ response: AgentTurnResponse, streamed: Bool, state: AgentRunState,
                         costReached: Bool) -> [AgentDiagnostic.Metric: Int] {
        diagnosticMetrics.merging([
            .maxOutputTokens: tokens, .hardMaxOutputTokens: ceiling, .outputRetries: retries,
            .visibleTextScalars: response.text.unicodeScalars.count, .streamedText: streamed ? 1 : 0,
            .costLimitReached: costReached ? 1 : 0, .turnIndex: state.turns, .maxTurns: state.allowedTurns
        ]) { _, current in current }
    }

    mutating func didRecover() { retries += 1 }
}

extension AgentTurnResponse {
    /// Fixed numeric vocabulary only: provider text, arguments and reasoning content never enter logs.
    var diagnosticMetrics: [AgentDiagnostic.Metric: Int] {
        var metrics: [AgentDiagnostic.Metric: Int] = [
            .visibleTextScalars: text.unicodeScalars.count, .returnedToolCalls: toolCalls.count,
            .discardedToolCalls: discardedToolCalls + (stopReason == .maxTokens ? toolCalls.count : 0),
            .outputLimited: stopReason == .maxTokens ? 1 : 0, .usageReported: usage == nil ? 0 : 1
        ]
        switch stopReason {
        case .endTurn: metrics[.modelStopReason] = 0
        case .toolUse: metrics[.modelStopReason] = 1
        case .maxTokens: metrics[.modelStopReason] = 2
        case .error: metrics[.modelStopReason] = 3
        case .aborted: metrics[.modelStopReason] = 4
        case .deferred: metrics[.modelStopReason] = 5
        case .other: metrics[.modelStopReason] = 6
        }
        if let usage {
            metrics[.inputTokens] = usage.inputTokens
            metrics[.outputTokens] = usage.outputTokens
            metrics[.reasoningTokens] = usage.reasoningTokens
        }
        if let message {
            metrics[.contentBlocks] = message.blocks.count
            metrics[.thinkingBlocks] = message.blocks.filter { if case .thinking = $0.content { return true }; return false }.count
            metrics[.invalidToolCalls] = message.toolCalls.filter { !$0.hasValidArguments }.count
            metrics[.incompleteToolCalls] = message.blocks.filter { if case .toolCall(_, false) = $0.content { return true }; return false }.count
        }
        return metrics
    }
}

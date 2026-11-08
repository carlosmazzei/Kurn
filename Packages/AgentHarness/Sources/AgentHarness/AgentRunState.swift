import Foundation

struct AgentRunState: Sendable {
    var history: [AgentMessage]
    var context: [AgentMessage]
    var usage = AgentUsage()
    var cost = 0.0
    var toolCalls = 0
    var requestedCalls = 0
    var turns = 0
    var finalText = ""
    var firstLimit: AgentRunStopReason?
    var allowedTurns = 0
    var allowedToolCalls = 0
    var progressCalls = 0
    var callsSinceProgress = 0
    var successfulInputs = Set<String>()
    /// Tokens the provider reported for the latest turn (its input plus its reply) and the
    /// context length once that reply was appended. Later messages are estimated on top of it;
    /// a compaction clears it, since the reported size no longer describes the context.
    var usageAnchor: (tokens: Int, contextCount: Int)?

    mutating func recordProgress(call: AgentToolCall, output: AgentToolOutput, isError: Bool) {
        callsSinceProgress += 1
        let madeProgress = (output.metrics[.returnedScalars] ?? 0) > 0 || (output.metrics[.returnedItems] ?? 0) > 0
            || (output.metrics[.mutationsCommitted] ?? 0) > 0
        if !isError && madeProgress {
            let input = call.name + "\0" + ((try? call.arguments.encodedString()) ?? call.rawArguments)
            if self.successfulInputs.insert(input).inserted {
                progressCalls += 1
                callsSinceProgress = 0
            }
        }
    }

    mutating func extendBudget(_ reason: AgentRunStopReason, limits: AgentLimits, trace: AgentTraceEmitter) -> Bool {
        guard let policy = limits.continuation else { return false }
        let facts: [AgentDiagnostic.Metric: Int] = [
            .maxTurns: allowedTurns, .maxToolCalls: allowedToolCalls, .progressCalls: progressCalls,
            .minimumProgress: policy.minimumProgress, .idleCalls: callsSinceProgress,
            .hardMaxTurns: policy.maxTurns, .hardMaxToolCalls: policy.maxToolCalls
        ]
        guard progressCalls >= policy.minimumProgress, callsSinceProgress < 8 else {
            trace.record(.budgetExtensionDenied, metrics: facts, reason: reason)
            return false
        }
        let turns = max(self.allowedTurns, min(policy.maxTurns, self.allowedTurns + policy.turnStep))
        let calls = max(self.allowedToolCalls, min(policy.maxToolCalls, self.allowedToolCalls + policy.toolStep))
        guard reason == .turnLimit ? turns > self.allowedTurns : calls > self.allowedToolCalls else {
            trace.record(.budgetExtensionDenied, metrics: facts, reason: reason)
            return false
        }
        self.allowedTurns = turns
        self.allowedToolCalls = calls
        trace.record(.budgetExtended, metrics: [.maxTurns: turns, .maxToolCalls: calls, .progressCalls: self.progressCalls], reason: reason)
        self.progressCalls = 0
        return true
    }
}

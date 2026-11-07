import AgentHarness

public extension AgentContextPolicy {
    init(budget: ContextBudget, compactionThreshold: Double = 0.75, keepRecentMessages: Int = 8) {
        self.init(inputTokenBudget: budget.inputTokens, compactionThreshold: compactionThreshold,
                  keepRecentMessages: keepRecentMessages)
    }
}

public extension NativeHarness {
    /// Uses the app's model budget and script-aware token estimates.
    init(model: any AgentModel, contextBudget: ContextBudget,
         limits: AgentLimits = AgentLimits(), costEstimator: (@Sendable (AgentUsage) -> Double)? = nil,
         compactionThreshold: Double = 0.75, keepRecentMessages: Int = 8,
         confirm: @escaping @Sendable (AgentToolCall) async -> Bool = { _ in false }) {
        self.init(model: model, limits: limits, costEstimator: costEstimator,
                  contextPolicy: AgentContextPolicy(budget: contextBudget, compactionThreshold: compactionThreshold,
                                                    keepRecentMessages: keepRecentMessages),
                  tokenEstimator: { TokenEstimate.tokens(in: $0) }, confirm: confirm)
    }
}

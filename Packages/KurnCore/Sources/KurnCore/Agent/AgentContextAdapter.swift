import AgentHarness

public extension AgentContextPolicy {
    init(budget: ContextBudget, compactionThreshold: Double = 0.75, keepRecentMessages: Int = 8) {
        self.init(inputTokenBudget: budget.inputTokens, compactionThreshold: compactionThreshold,
                  keepRecentMessages: keepRecentMessages)
    }
}

public extension NativeHarness {
    /// Uses the app's model budget and script-aware token estimates. A provider rejecting a turn as
    /// too long (`AppError.isContextOverflow`) is compacted against and retried once.
    init(model: any AgentModel, contextBudget: ContextBudget,
         limits: AgentLimits = AgentLimits(), costEstimator: (@Sendable (AgentUsage) -> Double)? = nil,
         compactionThreshold: Double = 0.75, keepRecentMessages: Int = 8,
         confirm: @escaping @Sendable (AgentToolCall) async -> Bool = { _ in false }) {
        self.init(model: model, limits: limits, costEstimator: costEstimator,
                  contextPolicy: AgentContextPolicy(budget: contextBudget, compactionThreshold: compactionThreshold,
                                                    keepRecentMessages: keepRecentMessages),
                  tokenEstimator: { TokenEstimate.tokens(in: $0) },
                  isContextOverflow: { ($0 as? AppError)?.isContextOverflow == true }, confirm: confirm)
    }
}

public extension AgentLimits {
    /// Chat limits sized to the selected sources. A library question over twenty meetings needs at
    /// least a listing, a search and a read per meeting, which the fixed 10-turn/20-call defaults
    /// cut off; context size is governed separately by compaction against the model's budget.
    /// Runs end with a tool-less wrap-up answer rather than bare tool results.
    static func chat(sourceCount: Int, maxCostUSD: Double? = nil) -> AgentLimits {
        let sources = max(0, sourceCount)
        return AgentLimits(maxTurns: min(maxChatTurns, max(10, 8 + sources / 2)),
                           maxToolCalls: min(maxChatToolCalls, max(20, 12 + sources * 3)),
                           maxCostUSD: maxCostUSD, wrapUpOnLimit: true)
    }

    static let maxChatTurns = 24
    static let maxChatToolCalls = 96
}

import AgentHarness

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

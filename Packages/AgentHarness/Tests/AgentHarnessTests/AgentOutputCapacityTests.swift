import Testing
@testable import AgentHarness

struct AgentOutputCapacityTests {
    @Test func advertisedOutputCapAppliesToCompactionAndNormalTurns() async throws {
        let policy = AgentContextPolicy(contextWindow: 1_000, maxOutputTokens: 8)
        #expect(policy.historySummaryMaxOutputTokens == 8)
        #expect(policy.turnPrefixSummaryMaxOutputTokens == 8)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Summary"), AgentTurnResponse(text: "Answer")])
        let history: [AgentMessage] = [.user(String(repeating: "中", count: 800)),
                                      .assistant(text: String(repeating: "中", count: 800), toolCalls: [])]
        let harness = NativeHarness(model: model, contextPolicy: policy)
        let events = try await agentEvents(harness, history: history)
        #expect(try agentOutcome(events).stopReason == .completed)
        #expect(await model.requests.count == 2)
        #expect(await model.requests.allSatisfy { $0.maxOutputTokens <= 8 })
        #expect(AgentContextPolicy(contextWindow: 1_000, maxOutputTokens: 0).maxOutputTokens == nil)
    }
}

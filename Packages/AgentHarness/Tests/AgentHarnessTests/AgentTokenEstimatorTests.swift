import Testing
@testable import AgentHarness

@Suite struct AgentTokenEstimatorTests {
    @Test(arguments: ["", "a", "abcd", "abcde", "中文😀"])
    func defaultEstimator(text: String) {
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(inputTokenBudget: 100))
        let framing = compactor.estimateTokens(systemPrompt: "", messages: [], tools: [])
        #expect(compactor.estimateTokens(systemPrompt: text, messages: [], tools: []) - framing == (text.count + 3) / 4)
    }

    @Test func customEstimatorAndNegativeEstimates() {
        let policy = AgentContextPolicy(inputTokenBudget: 10, keepRecentMessages: 1)
        let custom = AgentContextCompactor(policy: policy, tokenEstimator: { $0.isEmpty ? 0 : 9 })
        #expect(custom.estimateTokens(systemPrompt: "x", messages: [.user("data")], tools: []) == 27)
        let negative = AgentContextCompactor(policy: policy, tokenEstimator: { _ in -1 })
        #expect(negative.estimateTokens(systemPrompt: "x", messages: [.user("data")], tools: []) == 0)
        let messages: [AgentMessage] = [.assistant(text: "", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "lookup", content: "very long result", isError: false), .user("new")]
        #expect(custom.elidingOldResults(in: messages) == messages)
        #expect(custom.replacingOlderPrefix(in: messages, summary: "short") == messages)
    }

    @Test func harnessUsesInjectedEstimator() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
        let harness = NativeHarness(model: model, contextPolicy: AgentContextPolicy(inputTokenBudget: 1),
                                    tokenEstimator: { _ in 0 })
        let events = try await agentEvents(harness, history: [.user(String(repeating: "facts", count: 500))])
        #expect(try agentOutcome(events).finalText == "Answer")
        #expect(await model.requests.count == 1)
        #expect(!events.contains { if case .contextCompacted = $0 { return true }; return false })
    }
}

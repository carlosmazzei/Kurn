import Testing
@testable import AgentHarness

@Suite struct AgentTokenEstimatorTests {
    @Test(arguments: ["", "a", "abcd", "abcde", "中文😀"])
    func defaultEstimator(text: String) {
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(contextWindow: 100))
        let framing = compactor.estimateTokens(systemPrompt: "", messages: [], tools: [])
        #expect(compactor.estimateTokens(systemPrompt: text, messages: [], tools: []) - framing == (text.count + 3) / 4)
    }

    @Test func customEstimatorAndNegativeEstimates() {
        let policy = AgentContextPolicy(contextWindow: 10)
        let custom = AgentContextCompactor(policy: policy, tokenEstimator: { $0.isEmpty ? 0 : 9 })
        let overhead = AgentContextCompactor.messageOverheadTokens
        #expect(custom.estimateTokens(systemPrompt: "x", messages: [.user("data")], tools: []) == 18 + overhead)
        let negative = AgentContextCompactor(policy: policy, tokenEstimator: { _ in -1 })
        #expect(negative.estimateTokens(systemPrompt: "x", messages: [.user("data")], tools: []) == overhead)
        let messages: [AgentMessage] = [.assistant(text: "", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "lookup", content: "very long result", isError: false), .user("new")]
        // Four messages/calls of framing; call id, name and arguments, result id and content, and "new".
        #expect(custom.estimateTokens(of: messages) == 4 * overhead + 6 * 9)
    }

    @Test func harnessUsesInjectedEstimator() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
        // The default characters/4 estimate would compact this history in a 100-token window.
        let facts = String(repeating: "facts", count: 500)
        let harness = NativeHarness(model: model, contextPolicy: AgentContextPolicy(contextWindow: 100),
                                    tokenEstimator: { _ in 0 })
        let events = try await agentEvents(harness, history: [.user(facts), .assistant(text: facts, toolCalls: [])])
        #expect(try agentOutcome(events).finalText == "Answer")
        #expect(await model.requests.count == 1)
        #expect(!events.contains { if case .contextCompacted = $0 { return true }; return false })
    }

    @Test func toolResultsAreCountedOnceNotReencoded() {
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(contextWindow: 100))
        let json = String(repeating: "{\"text\":\"quoted \\\"value\\\"\"}", count: 50)
        let result = AgentMessage.toolResult(callID: "call", toolName: "read", content: json, isError: false)
        let overhead = AgentContextCompactor.messageOverheadTokens
        #expect(compactor.estimateTokens(of: result) == overhead + 1 + (json.count + 3) / 4)
        let call = AgentToolCall(id: "c", name: "read", arguments: .object([:]), rawArguments: "{\"a\":1}")
        let assistant = AgentMessage.assistant(text: "abcd", toolCalls: [call], providerMetadata: .string("sig"))
        let metadata = (try? JSONValue.string("sig").encodedString()) ?? ""
        #expect(compactor.estimateTokens(of: assistant) == overhead + 1 + overhead + 1 + 1 + 2
            + (metadata.count + 3) / 4)
    }
}

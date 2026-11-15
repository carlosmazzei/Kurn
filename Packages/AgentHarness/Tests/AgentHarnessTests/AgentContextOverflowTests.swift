import Testing
@testable import AgentHarness

struct AgentContextOverflowTests {
    @Test(arguments: [
        (400, "context_length_exceeded", true),
        (422, "input token count exceeds the maximum number of tokens", true),
        (0, "Your input exceeds the context window", true),
        (413, "Request too large", true),
        (413, "Rate limit: too many requests", false),
        (429, "context length exceeded", false),
        (500, "context length exceeded", false),
        (400, "invalid model", false)
    ])
    func classifiesProviderFacts(status: Int, message: String, expected: Bool) {
        #expect(AgentContextOverflow.matches(statusCode: status, message: message) == expected)
    }

    @Test func defaultRuntimeRecognizesTheHostErrorContract() async throws {
        struct Overflow: AgentContextOverflowError { let isContextOverflow = true }
        let model = ResultScriptedAgentModel([.failure(Overflow()), .success(AgentTurnResponse(text: "Summary")),
                                             .success(AgentTurnResponse(text: "Answer"))])
        let history: [AgentMessage] = [.user("Earlier request"),
            .assistant(text: String(repeating: "facts ", count: 150), toolCalls: []), .user("Recent request")]
        let harness = NativeHarness(model: model, contextWindow: 10_000, keepRecentTokens: 10)
        let events = try await agentEvents(harness, history: history)
        #expect(try agentOutcome(events).finalText == "Answer")
        #expect(await model.requests.count == 3)
        #expect(events.contains { if case .contextCompacted = $0 { return true }; return false })
    }
}

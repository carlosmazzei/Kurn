import Testing
@testable import AgentHarness

struct NativeHarnessDefaultsTests {
    @Test func harnessUsesScriptAwareEstimate() async throws {
        // 800 CJK characters: ~800 tokens to TokenEstimate, ~200 to a characters/4 estimate.
        let cjk = String(repeating: "会议", count: 400)
        let history: [AgentMessage] = [.user(cjk), .assistant(text: cjk, toolCalls: [])]
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Summary"), AgentTurnResponse(text: "Answer")])
        let harness = NativeHarness(model: model, contextWindow: 1_000)
        let events = try await agentEvents(harness, history: history)
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[0].tools.isEmpty)
        #expect(requests[1].messages.first.map { message in
            if case .user(let text) = message.legacyProjection { return text.hasPrefix(AgentContextCompactor.summaryPrefix) }
            return false
        } == true)
        #expect(events.contains { if case .contextCompacted = $0 { return true }; return false })
        #expect(try agentOutcome(events).finalText == "Answer")
    }

    @Test func limitsAndConfirmationAreForwarded() async throws {
        let call = agentCall()
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [call]), AgentTurnResponse(text: "Answer")])
        let tool = AgentTool(spec: AgentToolSpec(name: "lookup", description: "Read", inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(true)])),
                             requiresConfirmation: true) { _ in AgentToolOutput(content: "data", summary: "Read") }
        let harness = NativeHarness(model: model, contextWindow: 128_000, limits: AgentLimits(maxTurns: 1),
                                    costEstimator: { _ in 0 }, confirm: { approved in approved.id == call.id && approved.rawArguments == call.rawArguments })
        let events = try await agentEvents(harness, tools: [tool])
        #expect(events.contains(.toolFinished(callID: "1", name: "lookup", summary: "Read", isError: false)))
        #expect(try agentOutcome(events).stopReason == .turnLimit)
    }

}

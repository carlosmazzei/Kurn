import AgentHarness
import Testing
@testable import KurnCore

@Suite struct AgentContextAdapterTests {
    @Test func budgetPolicy() {
        let policy = AgentContextPolicy(budget: .onDevice, compactionThreshold: 0.5, keepRecentMessages: 2)
        #expect(policy.inputTokenBudget == ContextBudget.onDevice.inputTokens)
        #expect(policy.compactionThreshold == 0.5)
        #expect(policy.keepRecentMessages == 2)
    }

    @Test(arguments: ["", "meeting facts", "中文会议记录😀"])
    func harnessUsesScriptAwareEstimate(text: String) async throws {
        let history: [AgentMessage] = [.user(String(repeating: text, count: 100))]
        let policy = AgentContextPolicy(budget: ContextBudget(inputTokens: 1, mapBlockTokens: 1), keepRecentMessages: 1)
        let compactor = AgentContextCompactor(policy: policy, tokenEstimator: { TokenEstimate.tokens(in: $0) })
        let messages = history + [.user("Question")]
        let before = compactor.estimateTokens(systemPrompt: "Be helpful", messages: messages, tools: [])
        let model = ScriptedAgentModel([AgentTurnResponse(text: "s"), AgentTurnResponse(text: "Answer")])
        let harness = NativeHarness(model: model, contextBudget: ContextBudget(inputTokens: 1, mapBlockTokens: 1),
                                    keepRecentMessages: 1)
        let events = try await agentEvents(harness, history: history)
        let after = compactor.estimateTokens(systemPrompt: "Be helpful",
                                             messages: compactor.replacingOlderPrefix(in: messages, summary: "s"), tools: [])
        if before != after {
            #expect(events.contains(.contextCompacted(beforeTokens: before, afterTokens: after)))
        }
        #expect(await model.requests.count == 2)
        #expect(try agentOutcome(events).finalText == "Answer")
    }

    @Test func limitsAndConfirmationAreForwarded() async throws {
        let call = agentCall()
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [call]), AgentTurnResponse(text: "Answer")])
        let tool = AgentTool(spec: AgentToolSpec(name: "lookup", description: "Read", inputSchema: .object([:])),
                             requiresConfirmation: true) { _ in AgentToolOutput(content: "data", summary: "Read") }
        let harness = NativeHarness(model: model, contextBudget: .conservative, limits: AgentLimits(maxTurns: 1),
                                    costEstimator: { _ in 0 }, confirm: { approved in approved == call })
        let events = try await agentEvents(harness, tools: [tool])
        #expect(events.contains(.toolFinished(callID: "1", name: "lookup", summary: "Read", isError: false)))
        #expect(try agentOutcome(events).stopReason == .turnLimit)
    }
}

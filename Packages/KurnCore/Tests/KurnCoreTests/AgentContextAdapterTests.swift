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

    @Test func providerContextOverflowIsCompactedAndRetried() async throws {
        let text = String(repeating: "meeting facts [12:34] Alice ", count: 38)
        let history: [AgentMessage] = [
            .user("Earlier"), .assistant(text: "", toolCalls: [agentCall("0")]),
            .toolResult(callID: "0", toolName: "lookup", content: text, isError: false),
            .assistant(text: "Earlier answer", toolCalls: [])
        ]
        let model = OverflowOnceAgentModel(AppError.apiError(statusCode: 400,
            message: "This model's maximum context length is 128000 tokens."))
        let harness = NativeHarness(model: model, contextBudget: ContextBudget(inputTokens: 1_000, mapBlockTokens: 500),
                                    keepRecentMessages: 1)
        let outcome = try agentOutcome(await agentEvents(harness, history: history))
        #expect(outcome.finalText == "Answer")
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages[2] == history[2])
        #expect(requests[1].messages[2] != history[2])
    }

    @Test func unrelatedProviderErrorsAreNotRetried() async {
        let model = OverflowOnceAgentModel(AppError.apiError(statusCode: 400, message: "invalid model"))
        let harness = NativeHarness(model: model, contextBudget: ContextBudget(inputTokens: 1_000, mapBlockTokens: 500))
        await #expect(throws: AppError.self) {
            try await agentEvents(harness, history: [.user(String(repeating: "facts ", count: 300))])
        }
        #expect(await model.requests.count == 1)
    }

    @Test(arguments: [(0, 10, 20), (5, 10, 27), (20, 18, 72), (40, 24, 96), (1_000, 24, 96), (-3, 10, 20)])
    func chatLimitsScaleWithSources(sources: Int, turns: Int, toolCalls: Int) {
        let limits = AgentLimits.chat(sourceCount: sources, maxCostUSD: 2)
        #expect(limits.maxTurns == turns)
        #expect(limits.maxToolCalls == toolCalls)
        #expect(limits.maxCostUSD == 2)
        #expect(limits.wrapUpOnLimit)
    }
}

/// Throws one provider error, then answers.
actor OverflowOnceAgentModel: AgentModel {
    let error: AppError
    var requests: [AgentTurnRequest] = []

    init(_ error: AppError) {
        self.error = error
    }

    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        requests.append(request)
        if requests.count == 1 { throw error }
        return AgentTurnResponse(text: "Answer")
    }
}

import AgentHarness
import Testing
import KurnCore
@testable import Kurn

@Suite struct AgentContextAdapterTests {
    @Test func providerContextOverflowIsCompactedAndRetried() async throws {
        let text = String(repeating: "meeting facts [12:34] Alice ", count: 38)
        let history: [AgentMessage] = [
            .user("Earlier"), .assistant(text: "", toolCalls: [agentCall("0")]),
            .toolResult(callID: "0", toolName: "lookup", content: text, isError: false),
            .assistant(text: "Earlier answer", toolCalls: [])
        ]
        let model = OverflowOnceAgentModel(AppError.apiError(statusCode: 400,
            message: "This model's maximum context length is 128000 tokens."))
        let harness = NativeHarness(model: model, contextWindow: 1_000)
        let outcome = try agentOutcome(await agentEvents(harness, history: history))
        #expect(outcome.finalText == "Answer")
        #expect(Array(outcome.messages.prefix(history.count)) == history)
        let requests = await model.requests
        #expect(requests.count == 3)
        #expect(requests[0].messages[2] == history[2])
        #expect(requests[1].tools.isEmpty)
        #expect(requests[2].messages.count == 3)
        #expect(requests[2].messages[1] == history[3])
    }

    @Test func unrelatedProviderErrorsAreNotRetried() async {
        let model = OverflowOnceAgentModel(AppError.apiError(statusCode: 400, message: "invalid model"))
        let harness = NativeHarness(model: model, contextWindow: 1_000)
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

import Foundation
import Testing
import AgentHarness
@testable import KurnCore

actor ScriptedAgentModel: AgentModel {
    enum Failure: Error { case exhausted, provider }
    var responses: [AgentTurnResponse]
    var requests: [AgentTurnRequest] = []
    let fails: Bool

    init(_ responses: [AgentTurnResponse], fails: Bool = false) {
        self.responses = responses
        self.fails = fails
    }

    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        requests.append(request)
        if fails { throw Failure.provider }
        guard !responses.isEmpty else { throw Failure.exhausted }
        let response = responses.removeFirst()
        onEvent(.textDelta(response.text))
        return response
    }
}

func agentCall(_ id: String = "1", name: String = "lookup", raw: String = "{}") -> AgentToolCall {
    AgentToolCall(id: id, name: name, arguments: (try? JSONValue.parse(raw)) ?? .null, rawArguments: raw)
}

func agentEvents(_ harness: NativeHarness, history: [AgentMessage] = [], tools: [AgentTool] = []) async throws
    -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in harness.run(systemPrompt: "Be helpful", history: history, prompt: "Question",
                                       tools: tools, maxOutputTokens: 512) {
        events.append(event)
    }
    return events
}

func agentOutcome(_ events: [AgentEvent]) throws -> AgentRunOutcome {
    let last = try #require(events.last)
    guard case .runFinished(let outcome) = last else {
        throw ScriptedAgentModel.Failure.exhausted
    }
    return outcome
}

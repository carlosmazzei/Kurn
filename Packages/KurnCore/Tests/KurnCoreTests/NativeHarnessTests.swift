import Foundation
import Testing
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

func agentTool(confirm: Bool = false, fails: Bool = false) -> AgentTool {
    AgentTool(spec: AgentToolSpec(name: "lookup", description: "Look up facts", inputSchema: .object([:])),
              requiresConfirmation: confirm) { arguments in
        if fails { throw ScriptedAgentModel.Failure.provider }
        return AgentToolOutput(content: try arguments.encodedString(), summary: "Found facts")
    }
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

@Suite struct NativeHarnessTests {
    @Test func plainAnswer() async throws {
        let usage = AgentUsage(inputTokens: 10, outputTokens: 3)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer", usage: usage)])
        let events = try await agentEvents(NativeHarness(model: model), history: [.user("Earlier")])
        #expect(events == [.runStarted, .turnStarted(index: 0), .textDelta("Answer"), .usage(usage),
                           .runFinished(AgentRunOutcome(messages: [.user("Earlier"), .user("Question"),
                               .assistant(text: "Answer", toolCalls: [])], finalText: "Answer",
                               stopReason: .completed, totalUsage: usage))])
        let request = try #require(await model.requests.first)
        #expect(request.systemPrompt == "Be helpful")
        #expect(request.maxOutputTokens == 512)
    }

    @Test(arguments: [1, 3]) func orderedTools(count: Int) async throws {
        let calls = (0..<count).map { agentCall(String($0), raw: "{\"index\":\($0)}") }
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Looking", toolCalls: calls),
                                        AgentTurnResponse(text: "Done")])
        let events = try await agentEvents(NativeHarness(model: model), tools: [agentTool()])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .completed)
        let request = try #require(await model.requests.last)
        #expect(request.messages.count == count + 2)
        for index in 0..<count {
            #expect(request.messages[index + 2] == .toolResult(callID: String(index), toolName: "lookup",
                                                              content: "{\"index\":\(index)}", isError: false))
        }
        let starts = events.compactMap { event -> String? in
            if case .toolStarted(let id, _, _) = event { return id }
            return nil
        }
        #expect(starts == calls.map(\.id))
    }

    @Test(arguments: ["unknown", "invalid", "throw", "decline"])
    func recoverableToolErrors(kind: String) async throws {
        let call = agentCall(name: kind == "unknown" ? "missing" : "lookup", raw: kind == "invalid" ? "{" : "{}")
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [call]), AgentTurnResponse(text: "Recovered")])
        let events = try await agentEvents(NativeHarness(model: model),
                                           tools: [agentTool(confirm: kind == "decline", fails: kind == "throw")])
        let outcome = try agentOutcome(events)
        #expect(outcome.finalText == "Recovered")
        guard case .toolResult(_, _, let content, let isError) = outcome.messages[2] else {
            Issue.record("Missing tool result")
            return
        }
        #expect(isError)
        let expected = ["unknown": "Unknown tool", "invalid": "Invalid JSON", "throw": "failed", "decline": "declined"]
        #expect(content.contains(try #require(expected[kind])))
        #expect(events.contains { if case .toolFinished(_, _, _, true) = $0 { return true }; return false })
    }

    @Test func approvedConfirmation() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()]), AgentTurnResponse(text: "Done")])
        let events = try await agentEvents(NativeHarness(model: model, confirm: { _ in true }),
                                           tools: [agentTool(confirm: true)])
        #expect(events.contains(.toolFinished(callID: "1", name: "lookup", summary: "Found facts", isError: false)))
    }

    @Test func turnLimit() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Working", toolCalls: [agentCall()])])
        let events = try await agentEvents(NativeHarness(model: model, limits: AgentLimits(maxTurns: 1)), tools: [agentTool()])
        #expect(try agentOutcome(events).stopReason == .turnLimit)
        let empty = try await agentEvents(NativeHarness(model: model, limits: AgentLimits(maxTurns: 0)))
        #expect(try agentOutcome(empty).messages == [.user("Question")])
    }

    @Test func toolLimitPreservesPairs() async throws {
        let calls = [agentCall("1"), agentCall("2"), agentCall("3")]
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls)])
        let events = try await agentEvents(NativeHarness(model: model, limits: AgentLimits(maxToolCalls: 1)),
                                           tools: [agentTool()])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .toolCallLimit)
        #expect(outcome.messages.count == 5)
        #expect(events.contains(.toolFinished(callID: "1", name: "lookup", summary: "Found facts", isError: false)))
        #expect(outcome.messages[3] == .toolResult(callID: "2", toolName: "lookup",
            content: "Tool not executed: toolCallLimit reached.", isError: true))
    }

    @Test func costLimitIncludesUsage() async throws {
        let usage = AgentUsage(inputTokens: 50, outputTokens: 10)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()], usage: usage)])
        let harness = NativeHarness(model: model, limits: AgentLimits(maxCostUSD: 0.5), costEstimator: { _ in 0.5 })
        let outcome = try agentOutcome(await agentEvents(harness, tools: [agentTool()]))
        #expect(outcome.stopReason == .costLimit)
        #expect(outcome.totalUsage == usage)
        let zero = try agentOutcome(await agentEvents(NativeHarness(model: model, limits: AgentLimits(maxCostUSD: 0))))
        #expect(zero.stopReason == .costLimit)
        #expect(await model.requests.count == 1)
    }

    @Test func modelFailurePropagates() async {
        await #expect(throws: ScriptedAgentModel.Failure.provider) {
            try await agentEvents(NativeHarness(model: ScriptedAgentModel([], fails: true)))
        }
    }

    @Test func emptyAnswerAndEmptyTools() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "")])
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model)))
        #expect(outcome.finalText.isEmpty)
        #expect(outcome.totalUsage == AgentUsage())
        #expect(outcome.stopReason == .completed)
    }
}

import Foundation
import Testing
@testable import AgentHarness

/// Replays a fixed script of responses or errors, recording each request.
actor ResultScriptedAgentModel: AgentModel {
    struct Overflow: Error {}
    var results: [Result<AgentTurnResponse, Error>]
    var requests: [AgentTurnRequest] = []

    init(_ results: [Result<AgentTurnResponse, Error>]) {
        self.results = results
    }

    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        requests.append(request)
        guard !results.isEmpty else { throw ScriptedAgentModel.Failure.exhausted }
        let response = try results.removeFirst().get()
        onEvent(.textDelta(response.text))
        return response
    }
}

@Suite struct AgentRealContextTests {
    /// ~300 estimated tokens: under a 1,000-token budget's 750 threshold on its own.
    let mediumText = String(repeating: "meeting facts [12:34] Alice ", count: 43)
    let stub = "[result of lookup elided to save context — call the tool again if needed]"

    func history() -> [AgentMessage] {
        [.user("Earlier question"), .assistant(text: "Lookup", toolCalls: [agentCall("0")]),
         .toolResult(callID: "0", toolName: "lookup", content: mediumText, isError: false),
         .assistant(text: "Earlier answer", toolCalls: [])]
    }

    func policy() -> AgentContextPolicy {
        AgentContextPolicy(inputTokenBudget: 1_000, keepRecentMessages: 1)
    }

    @Test(arguments: [false, true])
    func reportedUsageDrivesCompaction(reportsLargeUsage: Bool) async throws {
        let usage = reportsLargeUsage ? AgentUsage(inputTokens: 100_000) : nil
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()], usage: usage),
                                       AgentTurnResponse(text: "Answer")])
        let harness = NativeHarness(model: model, contextPolicy: policy())
        let events = try await agentEvents(harness, history: history(), tools: [agentTool()])
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages[2] == .toolResult(callID: "0", toolName: "lookup", content: mediumText, isError: false))
        let compacted = events.contains { if case .contextCompacted = $0 { return true }; return false }
        #expect(compacted == reportsLargeUsage)
        let second = requests[1].messages[2]
        #expect(second == .toolResult(callID: "0", toolName: "lookup",
                                      content: reportsLargeUsage ? stub : mediumText, isError: false))
        #expect(try agentOutcome(events).messages[2] == history()[2])
    }

    @Test func smallReportedUsageAvoidsPessimisticCompaction() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()], usage: AgentUsage(inputTokens: 1)),
                                       AgentTurnResponse(text: "", toolCalls: [agentCall("2")]),
                                       AgentTurnResponse(text: "Answer")])
        let big = String(repeating: "facts ", count: 160)
        let tool = AgentTool(spec: agentTool().spec) { _ in AgentToolOutput(content: big, summary: "Read") }
        let harness = NativeHarness(model: model, contextPolicy: policy())
        let events = try await agentEvents(harness, history: history(), tools: [tool])
        #expect(!events.contains { if case .contextCompacted = $0 { return true }; return false })
        #expect(await model.requests.last?.messages[2] == history()[2])
    }

    @Test func overflowCompactsAndRetriesOnce() async throws {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model, contextPolicy: policy(),
                                    isContextOverflow: { $0 is ResultScriptedAgentModel.Overflow })
        let events = try await agentEvents(harness, history: history())
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages[2] == history()[2])
        #expect(requests[1].messages[2] == .toolResult(callID: "0", toolName: "lookup", content: stub, isError: false))
        let outcome = try agentOutcome(events)
        #expect(outcome.finalText == "Answer")
        #expect(outcome.messages[2] == history()[2])
    }

    @Test(arguments: [false, true])
    func overflowRethrowsWhenNothingCanShrink(recognized: Bool) async {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .failure(ResultScriptedAgentModel.Overflow())])
        let harness = NativeHarness(model: model, contextPolicy: policy(),
                                    isContextOverflow: { _ in recognized })
        await #expect(throws: ResultScriptedAgentModel.Overflow.self) {
            try await agentEvents(harness)
        }
        #expect(await model.requests.count == 1)
    }

    @Test func overflowRetriesOnlyOnce() async {
        let overflow = Result<AgentTurnResponse, Error>.failure(ResultScriptedAgentModel.Overflow())
        let model = ResultScriptedAgentModel([overflow, overflow, .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model, contextPolicy: policy(), isContextOverflow: { _ in true })
        await #expect(throws: ResultScriptedAgentModel.Overflow.self) {
            try await agentEvents(harness, history: history())
        }
        #expect(await model.requests.count == 2)
    }

    @Test(arguments: [AgentRunStopReason.turnLimit, .toolCallLimit])
    func limitEndsWithToolLessWrapUp(reason: AgentRunStopReason) async throws {
        let limits = reason == .turnLimit ? AgentLimits(maxTurns: 1, wrapUpOnLimit: true)
            : AgentLimits(maxToolCalls: 1, wrapUpOnLimit: true)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall("1"), agentCall("2")]),
                                       AgentTurnResponse(text: "Partial answer", toolCalls: [agentCall("3")])])
        let events = try await agentEvents(NativeHarness(model: model, limits: limits), tools: [agentTool()])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == reason)
        #expect(outcome.finalText == "Partial answer")
        #expect(outcome.messages.last == .assistant(text: "Partial answer", toolCalls: []))
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[1].systemPrompt == "Be helpful\n\n" + NativeHarness.wrapUpInstruction)
        #expect(requests[1].tools == [agentTool().spec])
        #expect(requests[1].allowsToolCalls == false)
        #expect(requests[0].allowsToolCalls)
        #expect(events.contains(.turnStarted(index: 1)))
        #expect(!events.contains { if case .toolStarted(let id, _, _) = $0 { return id == "3" }; return false })
    }

    @Test func wrapUpIsSkippedWithoutToolResultsOrPastCost() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()])])
        let none = try agentOutcome(await agentEvents(
            NativeHarness(model: model, limits: AgentLimits(maxTurns: 0, wrapUpOnLimit: true))))
        #expect(none.stopReason == .turnLimit)
        let usageModel = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()],
                                                               usage: AgentUsage(inputTokens: 1))])
        let costOutcome = try agentOutcome(await agentEvents(
            NativeHarness(model: usageModel, limits: AgentLimits(maxTurns: 1, maxCostUSD: 1, wrapUpOnLimit: true),
                          costEstimator: { _ in 1 }), tools: [agentTool()]))
        #expect(costOutcome.stopReason == .costLimit)
        #expect(await usageModel.requests.count == 1)
        #expect(await model.requests.isEmpty)
    }

    @Test func wrapUpWithoutTextIsNoAnswer() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall("1")]),
                                       AgentTurnResponse(text: "", toolCalls: [agentCall("2")])])
        let events = try await agentEvents(
            NativeHarness(model: model, limits: AgentLimits(maxTurns: 1, wrapUpOnLimit: true)), tools: [agentTool()])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .turnLimit)
        #expect(outcome.finalText.isEmpty)
        #expect(outcome.messages.last == .toolResult(callID: "1", toolName: "lookup", content: "{}", isError: false))
        #expect(await model.requests.count == 2)
    }

    @Test func truncatedWrapUpReportsOutputLimit() async throws {
        let truncated = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall("1"), agentCall("2")]),
                                           AgentTurnResponse(text: "Partial ans", stopReason: .maxTokens)])
        let limited = try agentOutcome(await agentEvents(
            NativeHarness(model: truncated, limits: AgentLimits(maxToolCalls: 1, wrapUpOnLimit: true)),
            tools: [agentTool()]))
        #expect(limited.stopReason == .outputLimit)
        #expect(limited.finalText == "Partial ans")
        #expect(limited.messages.last == .assistant(text: "Partial ans", toolCalls: []))
    }

    @Test func overflowOnAWindowFarBelowTheBudgetStillElides() async throws {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model,
                                    contextPolicy: AgentContextPolicy(inputTokenBudget: 23_000, keepRecentMessages: 1),
                                    isContextOverflow: { _ in true })
        let outcome = try agentOutcome(await agentEvents(harness, history: history()))
        #expect(outcome.finalText == "Answer")
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[1].messages[2] == .toolResult(callID: "0", toolName: "lookup", content: stub, isError: false))
    }

    @Test func overflowWithNothingToElideSummarizesTheOlderPrefix() async throws {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .success(AgentTurnResponse(text: "Earlier facts")),
                                             .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model,
                                    contextPolicy: AgentContextPolicy(inputTokenBudget: 23_000, keepRecentMessages: 1),
                                    isContextOverflow: { _ in true })
        let history: [AgentMessage] = [.user(mediumText), .assistant(text: mediumText, toolCalls: [])]
        let outcome = try agentOutcome(await agentEvents(harness, history: history))
        #expect(outcome.finalText == "Answer")
        let requests = await model.requests
        #expect(requests.count == 3)
        #expect(requests[1].tools.isEmpty)
        #expect(requests[2].messages == [.user("[Summary of earlier conversation]\nEarlier facts"), .user("Question")])
    }

    @Test func summaryThatOverflowsDropsTheOlderPrefix() async throws {
        let overflow = Result<AgentTurnResponse, Error>.failure(ResultScriptedAgentModel.Overflow())
        let model = ResultScriptedAgentModel([overflow, overflow, .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model,
                                    contextPolicy: AgentContextPolicy(inputTokenBudget: 23_000, keepRecentMessages: 1),
                                    isContextOverflow: { $0 is ResultScriptedAgentModel.Overflow })
        let history: [AgentMessage] = [.user(mediumText), .assistant(text: mediumText, toolCalls: [])]
        let outcome = try agentOutcome(await agentEvents(harness, history: history))
        #expect(outcome.finalText == "Answer")
        #expect(Array(outcome.messages.prefix(2)) == history)
        let requests = await model.requests
        #expect(requests.count == 3)
        #expect(requests[1].tools.isEmpty)
        #expect(requests[2].messages == [.user(AgentContextCompactor.omittedPrefixNote), .user("Question")])
    }

    @Test func summaryProviderFailuresStillPropagate() async {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .failure(ScriptedAgentModel.Failure.provider)])
        let harness = NativeHarness(model: model,
                                    contextPolicy: AgentContextPolicy(inputTokenBudget: 23_000, keepRecentMessages: 1),
                                    isContextOverflow: { $0 is ResultScriptedAgentModel.Overflow })
        await #expect(throws: ScriptedAgentModel.Failure.provider) {
            try await agentEvents(harness, history: [.user(mediumText), .assistant(text: mediumText, toolCalls: [])])
        }
    }

    @Test func omittingPrefixKeepsRecentGroups() {
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(inputTokenBudget: 10, keepRecentMessages: 2))
        let messages: [AgentMessage] = [.user("Old"), .assistant(text: "", toolCalls: [agentCall("1")]),
            .toolResult(callID: "1", toolName: "lookup", content: "x", isError: false), .user("New")]
        #expect(compactor.omittingOlderPrefix(in: messages)
            == [.user(AgentContextCompactor.omittedPrefixNote)] + Array(messages.dropFirst(1)))
        #expect(compactor.omittingOlderPrefix(in: [.user("Only")]) == [.user("Only")])
    }
}

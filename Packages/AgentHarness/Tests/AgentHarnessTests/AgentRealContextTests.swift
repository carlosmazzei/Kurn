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
    let summary = AgentContextCompactor.summaryPrefix

    /// One turn whose prefix (question, lookup, result) can be summarized while its last answer is kept.
    func history() -> [AgentMessage] {
        [.user(tokens(50)), .assistant(text: "", toolCalls: [agentCall()]),
         .toolResult(callID: "1", toolName: "lookup", content: tokens(80), isError: false),
         .assistant(text: tokens(10), toolCalls: [])]
    }

    func policy(window: Int = 100_000) -> AgentContextPolicy {
        AgentContextPolicy(contextWindow: window, reserveTokens: 0, keepRecentTokens: 30)
    }

    func splitSummary(_ text: String) -> AgentMessage {
        .user(summary + "No prior history.\n\n---\n\n**Turn context (split turn):**\n\n" + text)
    }

    @Test(arguments: [false, true])
    func reportedUsageDrivesCompaction(reportsLargeUsage: Bool) async throws {
        let usage = reportsLargeUsage ? AgentUsage(inputTokens: 2_000) : nil
        let first = AgentTurnResponse(text: "", toolCalls: [agentCall()], usage: usage)
        let model = ScriptedAgentModel(reportsLargeUsage ? [first, AgentTurnResponse(text: "Prefix"), AgentTurnResponse(text: "Answer")]
                                       : [first, AgentTurnResponse(text: "Answer")])
        let history: [AgentMessage] = [.user(tokens(50)), .assistant(text: tokens(50), toolCalls: [])]
        let events = try await agentEvents(NativeHarness(model: model, contextPolicy: policy(window: 1_000)),
                                           history: history, tools: [agentTool()])
        let requests = await model.requests
        #expect(requests.count == (reportsLargeUsage ? 3 : 2))
        let compactions = events.compactMap { event -> Int? in
            if case .contextCompacted(let before, _) = event { return before }
            return nil
        }
        // The anchored size is the reported 2,000 tokens plus the one tool result appended since.
        #expect(compactions == (reportsLargeUsage ? [2_006] : []))
        if reportsLargeUsage {
            #expect(requests[1].tools.isEmpty)
            #expect(requests[2].messages.first == splitSummary("Prefix"))
            #expect(requests[2].messages.count == 5)
        }
        #expect(try agentOutcome(events).finalText == "Answer")
    }

    @Test func smallReportedUsageAvoidsPessimisticCompaction() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()],
                                                          usage: AgentUsage(inputTokens: 10, outputTokens: 2)),
                                       AgentTurnResponse(text: "Answer")])
        let tool = AgentTool(spec: agentTool().spec) { _ in AgentToolOutput(content: tokens(700), summary: "Read") }
        // 718 anchored input + 512 output fits 1,500; the pessimistic full-history estimate does not.
        let events = try await agentEvents(NativeHarness(model: model, contextPolicy: policy(window: 1_500)),
                                           history: [.user(tokens(400))], tools: [tool])
        #expect(!events.contains { if case .contextCompacted = $0 { return true }; return false })
        #expect(await model.requests.count == 2)
    }

    @Test func overflowCompactsAndRetriesOnce() async throws {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .success(AgentTurnResponse(text: "Prefix")),
                                             .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model, contextPolicy: policy(),
                                    isContextOverflow: { $0 is ResultScriptedAgentModel.Overflow })
        let outcome = try agentOutcome(await agentEvents(harness, history: history()))
        #expect(outcome.finalText == "Answer")
        #expect(Array(outcome.messages.prefix(4)) == history())
        let requests = await model.requests
        #expect(requests.count == 3)
        #expect(requests[0].messages.map(\.legacyProjection) == history() + [.user("Question")])
        #expect(requests[1].tools.isEmpty)
        #expect(requests[2].messages.map(\.legacyProjection) == [splitSummary("Prefix"), history()[3], .user("Question")])
    }

    @Test(arguments: [false, true])
    func overflowRethrowsWhenNothingCanShrink(recognized: Bool) async {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .failure(ResultScriptedAgentModel.Overflow())])
        let harness = NativeHarness(model: model, contextPolicy: policy(), isContextOverflow: { _ in recognized })
        await #expect(throws: ResultScriptedAgentModel.Overflow.self) {
            try await agentEvents(harness)
        }
        #expect(await model.requests.count == 1)
    }

    @Test func overflowRetriesOnlyOnce() async {
        let overflow = Result<AgentTurnResponse, Error>.failure(ResultScriptedAgentModel.Overflow())
        let model = ResultScriptedAgentModel([overflow, .success(AgentTurnResponse(text: "Prefix")), overflow,
                                             .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model, contextPolicy: policy(), isContextOverflow: { _ in true })
        await #expect(throws: ResultScriptedAgentModel.Overflow.self) {
            try await agentEvents(harness, history: history())
        }
        #expect(await model.requests.count == 3)
    }

    @Test(arguments: [false, true])
    func unusableSummaryAfterOverflowFallsBackToTheOmissionNote(summaryOverflows: Bool) async throws {
        let summaryResult: Result<AgentTurnResponse, Error> = summaryOverflows
            ? .failure(ResultScriptedAgentModel.Overflow())
            : .success(AgentTurnResponse(text: "Cut sho", stopReason: .maxTokens))
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()), summaryResult,
                                             .success(AgentTurnResponse(text: "Answer"))])
        let harness = NativeHarness(model: model, contextPolicy: policy(),
                                    isContextOverflow: { $0 is ResultScriptedAgentModel.Overflow })
        let outcome = try agentOutcome(await agentEvents(harness, history: history()))
        #expect(outcome.finalText == "Answer")
        let requests = await model.requests
        #expect(requests.count == 3)
        #expect(requests[2].messages.map(\.legacyProjection) == [.user(summary + AgentContextCompactor.omittedPrefixNote), history()[3],
                                         .user("Question")])
    }

    @Test func summaryProviderFailuresStillPropagate() async {
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .failure(ScriptedAgentModel.Failure.provider)])
        let harness = NativeHarness(model: model, contextPolicy: policy(),
                                    isContextOverflow: { $0 is ResultScriptedAgentModel.Overflow })
        await #expect(throws: ScriptedAgentModel.Failure.provider) {
            try await agentEvents(harness, history: history())
        }
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
        guard case .content(let wrapUp) = outcome.messages[outcome.messages.count - 2] else { Issue.record("Missing wrap-up audit"); return }
        #expect(wrapUp.text == "Partial answer" && wrapUp.toolCalls.map(\.id) == ["3"])
        guard case .toolResult("3", "lookup", _, true) = outcome.messages.last?.legacyProjection else { Issue.record("Missing blocked wrap-up result"); return }
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
        #expect(outcome.messages.map(\.legacyProjection).contains(.toolResult(callID: "1", toolName: "lookup", content: "{}", isError: false)))
        guard case .toolResult("2", "lookup", _, true) = outcome.messages.last?.legacyProjection else { Issue.record("Missing blocked result"); return }
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
        guard case .content(let final) = limited.messages.last else { Issue.record("Missing interrupted wrap-up audit"); return }
        #expect(final.text == "Partial ans" && final.stopReason == .maxTokens && final.toolCalls.isEmpty)
    }
}

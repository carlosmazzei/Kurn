import Foundation
import Testing
@testable import AgentHarness

/// `n` estimated tokens under the default characters/4 estimator.
func tokens(_ count: Int, _ letter: Character = "a") -> String { String(repeating: letter, count: count * 4) }

@Suite struct AgentContextTests {
    let longText = String(repeating: "meeting facts [12:34] Alice 42 meeting-id-7 ", count: 200)

    func policy(window: Int = 1_000, keep: Int = 100) -> AgentContextPolicy {
        AgentContextPolicy(contextWindow: window, reserveTokens: 0, keepRecentTokens: keep)
    }

    @Test func policyFollowsTheWindowMinusTheReserve() {
        let large = AgentContextPolicy(contextWindow: 200_000, maxOutputTokens: 128_000)
        #expect(large.compactionThreshold == 200_000 - AgentContextPolicy.defaultReserveTokens)
        #expect(large.effectiveKeepRecentTokens == AgentContextPolicy.defaultKeepRecentTokens)
        #expect(large.historySummaryMaxOutputTokens == 128_000)
        #expect(large.turnPrefixSummaryMaxOutputTokens == 128_000)
        let small = AgentContextPolicy(contextWindow: 10_000)
        #expect(small.compactionThreshold == 5_000)
        #expect(small.effectiveKeepRecentTokens == 2_500)
        let degenerate = AgentContextPolicy(contextWindow: 0, reserveTokens: -5, keepRecentTokens: 0)
        #expect(degenerate.contextWindow == 1)
        #expect(degenerate.reserveTokens == 0)
        #expect(degenerate.keepRecentTokens == 1)
        #expect(degenerate.effectiveKeepRecentTokens == 1)
    }

    @Test func cutAtATurnStartSummarizesWholeTurns() throws {
        let messages: [AgentMessage] = [.user(tokens(50)), .assistant(text: tokens(50), toolCalls: []),
                                        .user(tokens(60)), .assistant(text: tokens(60), toolCalls: [])]
        let plan = try #require(AgentContextCompactor(policy: policy()).plan(for: messages))
        #expect(plan.messagesToSummarize == Array(messages.prefix(2)))
        #expect(plan.turnPrefix.isEmpty)
        #expect(!plan.isSplitTurn)
        #expect(plan.kept == Array(messages.suffix(2)))
        #expect(plan.previousSummary == nil)
    }

    @Test func cutInsideATurnSplitsItAndNeverSeparatesResults() throws {
        let messages: [AgentMessage] = [.user(tokens(50)), .assistant(text: "", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "lookup", content: tokens(80), isError: false),
            .assistant(text: tokens(10), toolCalls: []), .user(tokens(30)), .assistant(text: tokens(30), toolCalls: [])]
        let plan = try #require(AgentContextCompactor(policy: policy()).plan(for: messages))
        #expect(plan.isSplitTurn)
        #expect(plan.messagesToSummarize.isEmpty)
        #expect(plan.turnPrefix == Array(messages.prefix(3)))
        #expect(plan.kept == Array(messages.suffix(3)))
        let trailing: [AgentMessage] = [.user(tokens(10)), .assistant(text: "", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "lookup", content: tokens(200), isError: false)]
        let resultPlan = try #require(AgentContextCompactor(policy: policy()).plan(for: trailing))
        #expect(resultPlan.turnPrefix == [trailing[0]])
        #expect(resultPlan.kept == Array(trailing.suffix(2)))
    }

    @Test func nothingToCompactWhenEverythingIsRecent() {
        let compactor = AgentContextCompactor(policy: policy())
        #expect(compactor.plan(for: []) == nil)
        #expect(compactor.plan(for: [.user(tokens(5)), .user(tokens(5))]) == nil)
        #expect(compactor.plan(for: [.user(tokens(500))]) == nil)
        #expect(compactor.plan(for: [.toolResult(callID: "1", toolName: "x", content: "y", isError: false)]) == nil)
        #expect(compactor.plan(for: [.user(AgentContextCompactor.summaryPrefix + "Old"), .user(tokens(500))]) == nil)
    }

    @Test func serializationLabelsMessagesAndClipsToolResults() {
        let call = AgentToolCall(id: "c", name: "lookup", arguments: .object([:]), rawArguments: #"{"q":1}"#)
        let long = String(repeating: "x", count: 3_000)
        let text = AgentContextCompactor.serialize([
            .user("Q"), .assistant(text: "A", toolCalls: [call]),
            .toolResult(callID: "c", toolName: "lookup", content: long, isError: false),
            .toolResult(callID: "c", toolName: "lookup", content: "bad", isError: true), .assistant(text: "", toolCalls: [])
        ])
        #expect(text == "[User]: Q\n\n[Assistant]: A\n\n[Assistant tool calls]: lookup({\"q\":1})\n\n"
            + "[Tool result lookup]: " + String(repeating: "x", count: 2_000) + "\n[... 1000 more characters truncated]"
            + "\n\n[Tool error lookup]: bad")
    }

    @Test func summariesUpdateThePreviousOneAndRebuildTheContext() throws {
        let compactor = AgentContextCompactor(policy: policy())
        let messages: [AgentMessage] = [.user(AgentContextCompactor.summaryPrefix + "Old facts"), .user(tokens(50)),
            .assistant(text: tokens(50), toolCalls: []), .user(tokens(60)), .assistant(text: tokens(60), toolCalls: [])]
        let plan = try #require(compactor.plan(for: messages))
        #expect(plan.previousSummary == "Old facts")
        #expect(plan.messagesToSummarize == Array(messages[1...2]))
        let request = try #require(compactor.historySummaryRequest(for: plan))
        #expect(request.tools.isEmpty)
        #expect(request.systemPrompt == AgentCompactionPrompts.standard.system)
        #expect(request.maxOutputTokens > 0 && request.maxOutputTokens <= compactor.policy.historySummaryMaxOutputTokens)
        guard case .user(let prompt)? = request.messages.first, request.messages.count == 1 else {
            Issue.record("Expected one serialized user message"); return
        }
        #expect(prompt.hasPrefix("<conversation>\n[User]: "))
        #expect(prompt.contains("<previous-summary>\nOld facts\n</previous-summary>"))
        #expect(prompt.hasSuffix(AgentCompactionPrompts.standard.updateSummary))
        #expect(compactor.turnPrefixSummaryRequest(for: plan) == nil)
        #expect(compactor.applying(plan, historySummary: "New facts", turnPrefixSummary: nil)
            == [.user(AgentContextCompactor.summaryPrefix + "New facts")] + Array(messages.suffix(2)))
        #expect(compactor.omitting(plan) == [.user(AgentContextCompactor.summaryPrefix + "Old facts\n\n"
            + AgentContextCompactor.omittedPrefixNote)] + Array(messages.suffix(2)))
    }

    @Test func splitTurnsGetAPrefixSummary() throws {
        let compactor = AgentContextCompactor(policy: policy())
        let messages: [AgentMessage] = [.user(tokens(50)), .assistant(text: tokens(80), toolCalls: []),
                                        .assistant(text: tokens(120), toolCalls: [])]
        let plan = try #require(compactor.plan(for: messages))
        #expect(compactor.historySummaryRequest(for: plan) == nil)
        let request = try #require(compactor.turnPrefixSummaryRequest(for: plan))
        #expect(request.maxOutputTokens > 0 && request.maxOutputTokens <= compactor.policy.turnPrefixSummaryMaxOutputTokens)
        guard case .user(let prompt)? = request.messages.first else { Issue.record("Missing prompt"); return }
        #expect(prompt.hasSuffix(AgentCompactionPrompts.standard.turnPrefix))
        #expect(!prompt.contains("<previous-summary>"))
        #expect(compactor.applying(plan, historySummary: nil, turnPrefixSummary: "Prefix")
            == [.user(AgentContextCompactor.summaryPrefix
                + "No prior history.\n\n---\n\n**Turn context (split turn):**\n\nPrefix"), messages[2]])
        let first = try #require(compactor.historySummaryRequest(for: AgentCompactionPlan(previousSummary: nil,
            messagesToSummarize: [.user("Q")], turnPrefix: [], kept: [])))
        guard case .user(let initial)? = first.messages.first else { Issue.record("Missing prompt"); return }
        #expect(initial.hasSuffix(AgentCompactionPrompts.standard.historySummary))
    }

    @Test(arguments: [false, true])
    func summaryRequestsFitASmallWindow(splitTurn: Bool) throws {
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(contextWindow: 8_192))
        #expect(compactor.policy.historySummaryMaxOutputTokens == 4_096)
        #expect(compactor.policy.turnPrefixSummaryMaxOutputTokens == 4_096)
        // Serialized input plus instructions exceed the window. Fit the input first,
        // then derive output from the remaining headroom using the same policy as normal turns.
        let messages: [AgentMessage] = [.user(tokens(4_000)), .assistant(text: tokens(4_000), toolCalls: []),
            splitTurn ? .assistant(text: tokens(4_000), toolCalls: []) : .user(tokens(4_000)),
            .assistant(text: tokens(10), toolCalls: [])]
        let plan = try #require(compactor.plan(for: messages))
        #expect(plan.isSplitTurn == splitTurn)
        let request = try #require(splitTurn ? compactor.turnPrefixSummaryRequest(for: plan)
                                             : compactor.historySummaryRequest(for: plan))
        #expect(request.maxOutputTokens >= 1 && request.maxOutputTokens <= 4_096)
        let input = compactor.estimateTokens(systemPrompt: request.systemPrompt, messages: request.messages, tools: [])
        #expect(input + request.maxOutputTokens <= 8_192)
        guard case .user(let prompt)? = request.messages.first else { Issue.record("Missing prompt"); return }
        #expect(prompt.hasPrefix("<conversation>\n" + AgentContextCompactor.truncatedConversationNote + "\n"))
    }

    @Test func thresholdCompactionSummarizesAndKeepsTheRecentTail() async throws {
        let usage = AgentUsage(inputTokens: 100, outputTokens: 20)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Turn summary", usage: usage),
                                       AgentTurnResponse(text: "Answer", usage: usage)])
        let history: [AgentMessage] = [.user(tokens(700)), .assistant(text: tokens(300), toolCalls: [])]
        let events = try await agentEvents(NativeHarness(model: model, contextPolicy: policy()), history: history,
                                           tools: [agentTool()])
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[0].tools.isEmpty)
        #expect(requests[0].systemPrompt == AgentCompactionPrompts.standard.system)
        #expect(requests[1].messages == [.user(AgentContextCompactor.summaryPrefix
            + "No prior history.\n\n---\n\n**Turn context (split turn):**\n\nTurn summary"), history[1], .user("Question")])
        #expect(requests[1].tools == [agentTool().spec])
        #expect(!events.contains(.textDelta("Turn summary")))
        let outcome = try agentOutcome(events)
        #expect(outcome.totalUsage == AgentUsage(inputTokens: 200, outputTokens: 40))
        #expect(Array(outcome.messages.prefix(history.count)) == history)
        let compaction = events.compactMap { event -> (Int, Int)? in
            if case .contextCompacted(let before, let after) = event { return (before, after) }
            return nil
        }
        #expect(compaction.count == 1)
        #expect(compaction.first.map { $0.0 > 1_000 && $0.1 < $0.0 } == true)
    }

    @Test func summaryCostStopsNextTurn() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Short summary", usage: AgentUsage(inputTokens: 10))])
        let harness = NativeHarness(model: model, limits: AgentLimits(maxCostUSD: 1), costEstimator: { _ in 1 },
                                    contextPolicy: AgentContextPolicy(contextWindow: 1))
        let events = try await agentEvents(harness, history: [.user(longText)])
        #expect(try agentOutcome(events).stopReason == .costLimit)
        #expect(await model.requests.count == 1)
    }

    @Test func summaryFailurePropagates() async {
        let harness = NativeHarness(model: ScriptedAgentModel([], fails: true),
                                    contextPolicy: AgentContextPolicy(contextWindow: 1))
        await #expect(throws: ScriptedAgentModel.Failure.provider) {
            try await agentEvents(harness, history: [.user(longText)])
        }
    }

    @Test func codableRoundTrips() throws {
        let value = try JSONValue.parse("{\"null\":null,\"bool\":true,\"number\":1.5,\"string\":\"hello\",\"array\":[false,2]}")
        #expect(try JSONValue.parse(value.encodedString()) == value)
        for scalar in [JSONValue.null, .bool(false), .number(-1), .string(""), .array([]), .object([:])] {
            #expect(try JSONValue.parse(scalar.encodedString()) == scalar)
        }
        let messages: [AgentMessage] = [.user("Earlier question"), .assistant(text: "Lookup", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "lookup", content: "Result", isError: false),
            .assistant(text: "No tools", toolCalls: [])]
        #expect(try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(messages)) == messages)
        #expect(throws: (any Error).self) { try JSONValue.parse("{bad}") }
        #expect(throws: (any Error).self) { try JSONValue.number(.infinity).encodedString() }
    }
}

actor AgentCancellationProbe: AgentModel {
    var started = false
    var cancelled = false

    func block() async throws -> AgentToolOutput {
        started = true
        do {
            try await Task.sleep(for: .seconds(300))
        } catch {
            cancelled = true
            throw error
        }
        return AgentToolOutput(content: "", summary: "")
    }

    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        _ = try await block()
        return AgentTurnResponse(text: "")
    }
}

@Suite struct AgentCancellationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func consumerCancellationReachesWork(duringTool: Bool) async throws {
        let probe = AgentCancellationProbe()
        let model: any AgentModel = duringTool
            ? ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()])]) : probe
        let tool = AgentTool(spec: agentTool().spec) { _ in try await probe.block() }
        let stream = NativeHarness(model: model).run(systemPrompt: "", history: [], prompt: "",
                                                     tools: [tool], maxOutputTokens: 10)
        let consumer = Task {
            for try await _ in stream { }
        }
        while !(await probe.started) { await Task.yield() }
        consumer.cancel()
        _ = await consumer.result
        while !(await probe.cancelled) { await Task.yield() }
        #expect(await probe.cancelled)
    }
}

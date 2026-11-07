import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentContextTests {
    let longText = String(repeating: "meeting facts [12:34] Alice 42 meeting-id-7 ", count: 200)

    func history(_ text: String) -> [AgentMessage] {
        [.user("Earlier question"), .assistant(text: "Lookup", toolCalls: [agentCall()]),
         .toolResult(callID: "1", toolName: "lookup", content: text, isError: false),
         .assistant(text: "Earlier answer", toolCalls: [])]
    }

    @Test func elisionWithoutSummary() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
        let harness = NativeHarness(model: model,
            contextPolicy: AgentContextPolicy(inputTokenBudget: 1_000, keepRecentMessages: 1))
        let original = history(longText)
        let events = try await agentEvents(harness, history: original)
        #expect(await model.requests.count == 1)
        let request = try #require(await model.requests.first)
        #expect(request.messages[2] == .toolResult(callID: "1", toolName: "lookup",
            content: "[result of lookup elided to save context — call the tool again if needed]", isError: false))
        #expect(Array(try agentOutcome(events).messages.prefix(4)) == original)
        #expect(events.contains { if case .contextCompacted(let before, let after) = $0 { return before > after }; return false })
    }

    @Test func summaryAndAccounting() async throws {
        let usage = AgentUsage(inputTokens: 100, outputTokens: 20)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Alice chose 42 [12:34] meeting-id-7", usage: usage),
                                       AgentTurnResponse(text: "Answer", usage: usage)])
        let harness = NativeHarness(model: model,
            contextPolicy: AgentContextPolicy(inputTokenBudget: 100, keepRecentMessages: 1))
        let original = [.user(longText)] + history(longText)
        let events = try await agentEvents(harness, history: original, tools: [agentTool()])
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[0].tools.isEmpty)
        #expect(requests[0].systemPrompt.contains("[mm:ss] citations and source identifiers"))
        #expect(requests[1].messages == [.user("[Summary of earlier conversation]\nAlice chose 42 [12:34] meeting-id-7"),
                                         .user("Question")])
        #expect(requests[1].tools == [agentTool().spec])
        #expect(!events.contains(.textDelta("Alice chose 42 [12:34] meeting-id-7")))
        #expect(try agentOutcome(events).totalUsage == AgentUsage(inputTokens: 200, outputTokens: 40))
        #expect(Array(try agentOutcome(events).messages.prefix(original.count)) == original)
    }

    @Test func summaryCostStopsNextTurn() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Short summary", usage: AgentUsage(inputTokens: 10))])
        let harness = NativeHarness(model: model, limits: AgentLimits(maxCostUSD: 1), costEstimator: { _ in 1 },
            contextPolicy: AgentContextPolicy(inputTokenBudget: 100, keepRecentMessages: 1))
        let events = try await agentEvents(harness, history: [.user(longText)])
        #expect(try agentOutcome(events).stopReason == .costLimit)
        #expect(await model.requests.count == 1)
    }

    @Test func pairingBoundaryAndShortResults() {
        let messages: [AgentMessage] = [.user("Old"), .assistant(text: "", toolCalls: [agentCall("1"), agentCall("2")]),
            .toolResult(callID: "1", toolName: "lookup", content: longText, isError: false),
            .toolResult(callID: "2", toolName: "lookup", content: "short", isError: true), .user("Recent")]
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(inputTokenBudget: 10, keepRecentMessages: 2))
        #expect(compactor.olderPrefixCount(in: messages) == 1)
        #expect(compactor.elidingOldResults(in: messages) == messages)
        #expect(compactor.summaryRequest(for: messages, maxOutputTokens: 20)?.messages == [.user("Old")])
        let all = AgentContextCompactor(policy: AgentContextPolicy(inputTokenBudget: 10, keepRecentMessages: 1))
        let elided = all.elidingOldResults(in: messages)
        #expect(elided[3] == messages[3])
        #expect(elided[2] != messages[2])
    }

    @Test func emptyAndNonReducingSummary() {
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(inputTokenBudget: 1_700))
        #expect(compactor.policy.inputTokenBudget == 1_700)
        #expect(compactor.summaryRequest(for: [], maxOutputTokens: 10) == nil)
        #expect(compactor.elidingOldResults(in: []).isEmpty)
        let small = AgentContextCompactor(policy: AgentContextPolicy(inputTokenBudget: 1, keepRecentMessages: 1))
        let messages: [AgentMessage] = [.user("Old"), .user("New")]
        #expect(small.replacingOlderPrefix(in: messages, summary: " ") == messages)
        #expect(small.replacingOlderPrefix(in: messages, summary: longText) == messages)
        #expect(small.estimateTokens(systemPrompt: longText, messages: [], tools: [agentTool().spec])
            > (longText.count + 3) / 4)
    }

    @Test func summaryFailurePropagates() async {
        let harness = NativeHarness(model: ScriptedAgentModel([], fails: true),
            contextPolicy: AgentContextPolicy(inputTokenBudget: 1, keepRecentMessages: 1))
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
        let messages = history("Result") + [.assistant(text: "No tools", toolCalls: [])]
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

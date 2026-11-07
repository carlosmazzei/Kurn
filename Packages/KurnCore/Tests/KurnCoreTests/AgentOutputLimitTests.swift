import Foundation
import Testing
@testable import KurnCore

@Suite struct AgentOutputLimitTests {
    @Test(arguments: [false, true], ["", "Partial answer"])
    func truncatedTurnNeverExecutesTools(hasTools: Bool, text: String) async throws {
        let usage = AgentUsage(inputTokens: 12, outputTokens: 10)
        let model = ScriptedAgentModel([AgentTurnResponse(text: text, toolCalls: hasTools ? [agentCall()] : [],
                                                         usage: usage, stopReason: .maxTokens)])
        let tool = AgentTool(spec: agentTool().spec) { _ in
            Issue.record("Truncated tool call must not execute")
            return AgentToolOutput(content: "Unsafe", summary: "Unsafe")
        }
        let events = try await agentEvents(NativeHarness(model: model), tools: [tool])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .outputLimit)
        #expect(outcome.finalText == text)
        #expect(outcome.totalUsage == usage)
        #expect(outcome.messages.last == .assistant(text: text, toolCalls: []))
        #expect(await model.requests.count == 1)
        #expect(!events.contains { if case .toolStarted = $0 { return true }; return false })
    }

    @Test(arguments: [false, true])
    func truncatedSummaryKeepsElidedContext(withToolResult: Bool) async throws {
        let longText = String(repeating: "Important fact [12:34] Alice 42 ", count: 500)
        let history: [AgentMessage] = [.user(longText)] + (withToolResult ? [
            .assistant(text: "Lookup", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "lookup", content: longText, isError: false)
        ] : [])
        let policy = AgentContextPolicy(inputTokenBudget: 100, keepRecentMessages: 1)
        let usage = AgentUsage(inputTokens: 100, outputTokens: 20)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Truncated summary", usage: usage, stopReason: .maxTokens),
                                       AgentTurnResponse(text: "Answer")])
        let events = try await agentEvents(NativeHarness(model: model, contextPolicy: policy), history: history)
        let requests = await model.requests
        #expect(requests.count == 2)
        let expected = AgentContextCompactor(policy: policy).elidingOldResults(in: history + [.user("Question")])
        #expect(requests[1].messages == expected)
        #expect(Array(try agentOutcome(events).messages.prefix(history.count)) == history)
        #expect(try agentOutcome(events).totalUsage == usage)
        #expect(try agentOutcome(events).stopReason == .completed)
    }

    @Test func stopReasonsRemainCodable() throws {
        for reason in [AgentRunStopReason.completed, .turnLimit, .toolCallLimit, .costLimit, .outputLimit] {
            let data = try JSONEncoder().encode(reason)
            #expect(try JSONDecoder().decode(AgentRunStopReason.self, from: data) == reason)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(reason.rawValue)\"")
        }
    }

    @Test(arguments: AgentWireFormat.allCases)
    func emptyWireOutputAtTokenLimit(format: AgentWireFormat) throws {
        let terminal: String
        switch format {
        case .anthropic: terminal = #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
        case .openAI: terminal = #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#
        case .gemini: terminal = #"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#
        }
        let accumulator = AgentWireAccumulator(format: format)
        _ = try accumulator.consume(terminal)
        let response = try accumulator.response()
        #expect(response.text.isEmpty)
        #expect(response.toolCalls.isEmpty)
        #expect(response.stopReason == .maxTokens)
    }

    @Test(arguments: AgentWireFormat.allCases)
    func truncatedWireCallsAreDiscarded(format: AgentWireFormat) throws {
        let payloads: [String]
        switch format {
        case .anthropic:
            payloads = [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","input":{}}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
            ]
        case .openAI:
            payloads = [#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{"}}]},"finish_reason":"length"}]}"#]
        case .gemini:
            payloads = [#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"read","args":{}}}]},"finishReason":"MAX_TOKENS"}]}"#]
        }
        let accumulator = AgentWireAccumulator(format: format)
        for payload in payloads { _ = try accumulator.consume(payload) }
        let response = try accumulator.response()
        #expect(response.stopReason == .maxTokens)
        #expect(response.toolCalls.isEmpty)
    }
}

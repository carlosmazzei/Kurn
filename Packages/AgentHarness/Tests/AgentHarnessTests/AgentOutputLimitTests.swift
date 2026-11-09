import Foundation
import Testing
@testable import AgentHarness

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
        guard case .content(let message) = outcome.messages[1] else { Issue.record("Missing interrupted assistant audit"); return }
        #expect(message.toolCalls == (hasTools ? [agentCall()] : []))
        #expect(message.text == text && message.stopReason == .maxTokens)
        if hasTools {
            guard case .toolResult("1", "lookup", _, true) = outcome.messages.last else { Issue.record("Missing blocked result"); return }
        } else { #expect(outcome.messages.count == 2) }
        #expect(await model.requests.count == 1)
        #expect(!events.contains { if case .toolStarted = $0 { return true }; return false })
    }

    @Test(arguments: [false, true])
    func truncatedSummaryLeavesTheContextUnchanged(withToolResult: Bool) async throws {
        let history: [AgentMessage] = [.user(tokens(600))] + (withToolResult ? [
            .assistant(text: "Lookup", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "lookup", content: tokens(600), isError: false)
        ] : [.assistant(text: tokens(600), toolCalls: [])])
        let policy = AgentContextPolicy(contextWindow: 1_000, reserveTokens: 0, keepRecentTokens: 100)
        let usage = AgentUsage(inputTokens: 100, outputTokens: 20)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Truncated summary", usage: usage, stopReason: .maxTokens),
                                       AgentTurnResponse(text: "Answer")])
        let events = try await agentEvents(NativeHarness(model: model, contextPolicy: policy), history: history)
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests[0].tools.isEmpty)
        #expect(requests[1].messages == history + [.user("Question")])
        #expect(!events.contains { if case .contextCompacted = $0 { return true }; return false })
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
        case .openAIResponses:
            terminal = #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
        case .gemini: terminal = #"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#
        }
        let accumulator = AgentWireAccumulator(format: format)
        _ = try accumulator.consume(terminal)
        if format == .anthropic { _ = try accumulator.consume(#"{"type":"message_stop"}"#) }
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
        case .openAIResponses:
            payloads = [
                #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","arguments":"{"}}"#,
                #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
            ]
        case .gemini:
            payloads = [#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"read","args":{}}}]},"finishReason":"MAX_TOKENS"}]}"#]
        }
        let accumulator = AgentWireAccumulator(format: format)
        for payload in payloads { _ = try accumulator.consume(payload) }
        if format == .anthropic { _ = try accumulator.consume(#"{"type":"message_stop"}"#) }
        let response = try accumulator.response()
        #expect(response.stopReason == .maxTokens)
        #expect(response.toolCalls.isEmpty)
        #expect(response.discardedToolCalls == 1)
    }
}

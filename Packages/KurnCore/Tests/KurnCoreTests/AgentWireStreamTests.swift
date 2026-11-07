import Foundation
import Testing
@testable import KurnCore

@Suite struct AgentWireStreamTests {
    func consume(_ payloads: [String], format: AgentWireFormat) throws -> (AgentTurnResponse, [AgentModelEvent]) {
        let accumulator = AgentWireAccumulator(format: format, callIDPrefix: "turn")
        var events: [AgentModelEvent] = []
        for payload in payloads { events += try accumulator.consume(payload) }
        return (try accumulator.response(), events)
    }

    @Test func anthropicTextAndUsage() throws {
        let (response, events) = try consume([
            #"{"type":"message_start","message":{"usage":{"input_tokens":30,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hi"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
            #"{"type":"message_stop"}"#
        ], format: .anthropic)
        #expect(events == [.textDelta("Hi"), .textDelta(" there")])
        #expect(response == AgentTurnResponse(text: "Hi there", usage: AgentUsage(inputTokens: 30, outputTokens: 5)))
    }

    @Test(arguments: [1, 2]) func anthropicToolsAndSplitJSON(count: Int) throws {
        var payloads = [
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"a","name":"search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"Alice\"}"}}"#
        ]
        if count == 2 {
            payloads += [#"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"b","name":"read","input":{"id":7}}}"#]
        }
        payloads += [#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#]
        let (response, events) = try consume(payloads, format: .anthropic)
        #expect(events.isEmpty)
        #expect(response.toolCalls.count == count)
        #expect(response.toolCalls[0] == AgentToolCall(id: "a", name: "search", arguments: .object(["q": .string("Alice")]),
                                                      rawArguments: #"{"q":"Alice"}"#))
        if count == 2 { #expect(response.toolCalls[1].arguments == .object(["id": .number(7)])) }
        #expect(response.stopReason == .toolUse)
        #expect(response.usage == AgentUsage(outputTokens: 9))
    }

    @Test func openAITextUsageAndChoiceSelection() throws {
        let (response, events) = try consume([
            #"{"choices":[{"index":1,"delta":{"content":"ignore"}},{"index":0,"delta":{"role":"assistant","content":"Hi"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"!"},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#,
            "[DONE]"
        ], format: .openAI)
        #expect(events == [.textDelta("Hi"), .textDelta("!")])
        #expect(response == AgentTurnResponse(text: "Hi!", usage: AgentUsage(inputTokens: 12, outputTokens: 3)))
    }

    @Test(arguments: [1, 2]) func openAIIndexedTools(count: Int) throws {
        var payloads = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"sea","arguments":"{\"q\":"}}]}}]}"#
        ]
        if count == 2 {
            payloads += [#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"read","arguments":"{}"}}]}}]}"#]
        }
        payloads += [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"rch","arguments":"\"Alice\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
        ]
        let (response, events) = try consume(payloads, format: .openAI)
        #expect(response.toolCalls.count == count)
        #expect(response.toolCalls[0].id == "a")
        #expect(response.toolCalls[0].name == "search")
        #expect(response.toolCalls[0].arguments == .object(["q": .string("Alice")]))
        #expect(response.stopReason == .toolUse)
        #expect(response.usage == nil)
        #expect(events.isEmpty)
    }

    @Test func geminiTextAndCumulativeUsage() throws {
        let (response, events) = try consume([
            #"{"candidates":[{"index":1,"content":{"parts":[{"text":"ignore"}]}},{"index":0,"content":{"parts":[{"thought":true,"text":"private"},{"text":"Hi"}]}}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":1}}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"!"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":2,"thoughtsTokenCount":4}}"#
        ], format: .gemini)
        #expect(events == [.textDelta("Hi"), .textDelta("!")])
        #expect(response == AgentTurnResponse(text: "Hi!", usage: AgentUsage(inputTokens: 12, outputTokens: 6)))
    }

    @Test(arguments: [1, 2]) func geminiToolsHaveStableIDs(count: Int) throws {
        var payloads = [
            #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"search","args":{"q":"Alice"}},"thoughtSignature":"signature"}]}}]}"#
        ]
        if count == 2 {
            payloads += [#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"read","args":{}}}]}}]}"#]
        }
        payloads += [#"{"candidates":[{"finishReason":"STOP"}]}"#]
        let accumulator = AgentWireAccumulator(format: .gemini, callIDPrefix: "turn")
        for payload in payloads { _ = try accumulator.consume(payload) }
        let response = try accumulator.response()
        #expect(try accumulator.response() == response)
        #expect(response.toolCalls.count == count)
        #expect(response.toolCalls.map(\.id) == (0..<count).map { "turn-\($0)" })
        #expect(response.toolCalls[0].arguments == .object(["q": .string("Alice")]))
        #expect(response.toolCalls[0].providerMetadata == .object(["thoughtSignature": .string("signature")]))
        #expect(response.stopReason == .toolUse)
        let followup = AgentTurnRequest(systemPrompt: "", messages: [.assistant(text: "", toolCalls: response.toolCalls)]
            + response.toolCalls.map { .toolResult(callID: $0.id, toolName: $0.name, content: "Found", isError: false) },
            tools: [], maxOutputTokens: 1)
        let contents = AgentWireFormat.gemini.requestBody(followup, model: "gemini")["contents"].array
        #expect(contents[0]["parts"].array[0]["thoughtSignature"] == .string("signature"))
        #expect(contents[1]["parts"].array.count == count)
        #expect(contents[1]["parts"].array[0]["functionResponse"]["name"] == .string("search"))
        #expect(contents[1]["parts"].array[0]["functionResponse"]["id"] == .null)
    }

    @Test func geminiWireIDsArePreserved() throws {
        let (response, _) = try consume([
            #"{"candidates":[{"content":{"parts":[{"functionCall":{"id":"native-id","name":"read"}}]},"finishReason":"STOP"}]}"#
        ], format: .gemini)
        #expect(response.toolCalls[0].id == "native-id")
        #expect(response.toolCalls[0].rawArguments == "{}")
        #expect(response.toolCalls[0].providerMetadata == .object(["geminiID": .string("native-id")]))
    }

    @Test(arguments: AgentWireFormat.allCases) func malformedPayloadsAndErrors(format: AgentWireFormat) throws {
        let accumulator = AgentWireAccumulator(format: format)
        for payload in ["garbage", "{", "null", "[]", "{}", #"{"choices":[],"candidates":[]}"#] {
            #expect(try accumulator.consume(payload).isEmpty)
        }
        #expect(throws: AgentWireError.emptyResponse) { try accumulator.response() }
        #expect(throws: AgentWireError.remote("Rate limited")) {
            try accumulator.consume(#"{"error":{"message":"Rate limited"}}"#)
        }
        #expect(throws: AgentWireError.remote("Stream error")) { try accumulator.consume(#"{"error":{}}"#) }
    }

    @Test func invalidArgumentsRetainRawText() throws {
        let (response, _) = try consume([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"read","arguments":"{bad"}}]},"finish_reason":"tool_calls"}]}"#
        ], format: .openAI)
        #expect(response.toolCalls[0].arguments == .null)
        #expect(response.toolCalls[0].rawArguments == "{bad")
        let accumulator = AgentWireAccumulator(format: .openAI)
        _ = try accumulator.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read"}}]}}]}"#)
        _ = try accumulator.consume(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        #expect(throws: AgentWireError.incompleteToolCall) { try accumulator.response() }
    }

    @Test(arguments: ["length", "content_filter", "function_call"])
    func openAIStopReasons(reason: String) throws {
        let payload = #"{"choices":[{"delta":{"content":"Hi"},"finish_reason":"\#(reason)"}]}"#
        let (response, _) = try consume([payload], format: .openAI)
        let expected: AgentModelStopReason = reason == "length" ? .maxTokens : reason == "function_call" ? .toolUse : .other(reason)
        #expect(response.stopReason == expected)
    }

    @Test(arguments: ["MAX_TOKENS", "SAFETY"]) func geminiStopReasons(reason: String) throws {
        let (response, _) = try consume([
            #"{"candidates":[{"content":{"parts":[{"text":"Hi"}]},"finishReason":"\#(reason)"}]}"#
        ], format: .gemini)
        #expect(response.stopReason == (reason == "MAX_TOKENS" ? .maxTokens : .other(reason)))
    }

    @Test(arguments: ["max_tokens", "stop_sequence", "pause_turn"]) func anthropicStopReasons(reason: String) throws {
        let (response, _) = try consume([
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"input_tokens":7}}"#
        ], format: .anthropic)
        let expected: AgentModelStopReason = reason == "max_tokens" ? .maxTokens : reason == "stop_sequence" ? .endTurn : .other(reason)
        #expect(response.stopReason == expected)
        #expect(response.usage?.inputTokens == 7)
    }
}

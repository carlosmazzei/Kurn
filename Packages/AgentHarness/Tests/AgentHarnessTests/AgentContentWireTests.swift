import Foundation
import Testing
@testable import AgentHarness

struct AgentContentWireTests {
    @Test func anthropicThinkingSignaturesAndInterleavedCallsRetainOrder() throws {
        let accumulator = AgentWireAccumulator(format: .anthropic, messageID: "message", requestID: "request", timestampMilliseconds: 123)
        let payloads = [
            #"{"type":"message_start","message":{"id":"response","model":"model","usage":{"input_tokens":12}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":"Answer"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call","name":"lookup","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{bad"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"opaque=="}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}"#
        ]
        var reducer = AgentMessageReducer()
        var visible = ""
        for payload in payloads {
            for event in try accumulator.consume(payload) {
                if case .content(let content) = event { try reducer.apply(content) }
                if case .textDelta(let text) = event { visible += text }
            }
        }
        _ = try accumulator.consume(#"{"type":"message_stop"}"#)
        let response = try accumulator.response()
        let message = try #require(response.message)
        #expect(message.blocks.map(\.id) == ["b0", "b1", "b2"])
        #expect(message.timestampMilliseconds == 123 && message.identity?.model == "model" && message.identity?.responseID == "response")
        #expect(message.blocks[0].content == .thinking(text: "private", signature: "opaque==", redacted: false))
        #expect(response.toolCalls[0].argumentError == .invalidJSON && response.toolCalls[0].rawArguments == "{bad")
        #expect(visible == "Answer")
        try reducer.apply(.messageFinished(message))
        #expect(reducer.blocks == message.blocks)
        let request = AgentTurnRequest(systemPrompt: "", messages: [.content(message)], tools: [], maxOutputTokens: 1)
        let prepared = AgentWireFormat.anthropic.requestProjection(request, model: "model")
        #expect(prepared.body["messages"].array[0]["content"].array[0]["signature"] == .string("opaque=="))
        #expect(prepared.adjustment.sanitizedArguments == 1)
    }

    @Test func responsesFinalCanCorrectRemoveAndReorderStreamedContent() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(#"{"type":"response.output_text.delta","output_index":0,"delta":"Wrong draft"}"#)
        _ = try accumulator.consume(AgentResponsesTests().added)
        _ = try accumulator.consume(#"""
            {"type":"response.completed","response":{"id":"response","model":"model","output":[
            {"type":"message","content":[{"type":"output_text","text":"Correct answer"}]}],
            "usage":{"input_tokens":15,"output_tokens":2,"output_tokens_details":{"reasoning_tokens":1}}}}
            """#)
        let response = try accumulator.response()
        #expect(response.text == "Correct answer" && response.toolCalls.isEmpty)
        #expect(response.message?.blocks.count == 1 && response.usage == AgentUsage(inputTokens: 15, outputTokens: 2, reasoningTokens: 1))
        #expect(try accumulator.consume(#"{"type":"response.output_text.delta","delta":"late"}"#).isEmpty)
        #expect(try accumulator.response() == response)
    }

    @Test func chatAndGeminiCumulativeUsageIncludesTrailingReasoningOnce() throws {
        let chat = AgentWireAccumulator(format: .openAI)
        _ = try chat.consume(#"{"id":"response","model":"model","choices":[{"delta":{"reasoning_content":"private","content":"A"}}]}"#)
        _ = try chat.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call","function":{"name":"lookup","arguments":"{}"}}]}}]}"#)
        _ = try chat.consume(#"{"choices":[{"delta":{"content":"B"},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":4}}"#)
        _ = try chat.consume(#"{"usage":{"prompt_tokens":10,"completion_tokens":8,"completion_tokens_details":{"reasoning_tokens":5}}}"#)
        #expect(try chat.response().usage == AgentUsage(inputTokens: 10, outputTokens: 8, reasoningTokens: 5))
        #expect(try chat.response().message?.blocks.count == 4)
        let gemini = AgentWireAccumulator(format: .gemini)
        _ = try gemini.consume(#"""
            {
              "modelVersion": "model",
              "responseId": "response",
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "thought": true,
                        "text": "private",
                        "thoughtSignature": "sig"
                      },
                      {
                        "text": "A"
                      },
                      {
                        "functionCall": {
                          "id": "call",
                          "name": "lookup",
                          "args": {}
                        },
                        "thoughtSignature": "call-sig"
                      }
                    ]
                  },
                  "finishReason": "STOP"
                }
              ],
              "usageMetadata": {
                "promptTokenCount": 10,
                "candidatesTokenCount": 3,
                "thoughtsTokenCount": 5
              }
            }
            """#)
        _ = try gemini.consume(#"{"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":3,"thoughtsTokenCount":7}}"#)
        let response = try gemini.response()
        #expect(response.usage == AgentUsage(inputTokens: 10, outputTokens: 10, reasoningTokens: 7))
        #expect(response.message?.blocks.count == 3 && response.message?.identity?.model == "model")
        #expect(response.toolCalls[0].providerMetadata?["thoughtSignature"] == .string("call-sig"))
    }

    @Test(arguments: [false, true]) func anthropicMissingBlockEndCannotBecomeExecutable(closed: Bool) throws {
        let accumulator = AgentWireAccumulator(format: .anthropic)
        _ = try accumulator.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"lookup","input":{}}}"#)
        if closed { _ = try accumulator.consume(#"{"type":"content_block_stop","index":0}"#) }
        _ = try accumulator.consume(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#)
        _ = try accumulator.consume(#"{"type":"message_stop"}"#)
        if closed { #expect(try accumulator.response().toolCalls.count == 1) }
        else { #expect(throws: AgentWireError.incompleteToolCall) { try accumulator.response() } }
    }

    @Test(arguments: AgentWireFormat.allCases) func outputLimitedCallsRemainInCanonicalAudit(format: AgentWireFormat) throws {
        let accumulator = AgentWireAccumulator(format: format)
        let start: String
        let end: String
        switch format {
        case .openAI:
            start = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call","function":{"name":"lookup","arguments":"{bad"}}]}}]}"#
            end = #"{"choices":[{"finish_reason":"length"}]}"#
        case .anthropic:
            start = #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"lookup","input":{}}}"#
            end = #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
        case .openAIResponses:
            start = #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call","name":"lookup","arguments":"{bad"}}"#
            end = #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
        case .gemini:
            start = #"{"candidates":[{"content":{"parts":[{"functionCall":{"id":"call","name":"lookup","args":{}}}]}}]}"#
            end = #"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#
        }
        _ = try accumulator.consume(start); _ = try accumulator.consume(end)
        if format == .anthropic { _ = try accumulator.consume(#"{"type":"message_stop"}"#) }
        let response = try accumulator.response()
        #expect(response.toolCalls.isEmpty && response.blockedToolCalls.count == 1)
        #expect(response.message?.toolCalls.count == 1 && response.discardedToolCalls == 1)
    }
    @Test func responsesFinalReorderKeepsKnownItemBlockIdentity() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        var blocks: [AgentContentBlock] = []
        let start = [
            #"{"type":"response.output_item.added","output_index":0,"item":{"id":"message-item","type":"message","content":[]}}"#,
            #"{"type":"response.output_text.delta","output_index":0,"item_id":"message-item","delta":"Draft"}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"id":"reasoning-item","type":"reasoning","encrypted_content":"opaque"}}"#
        ]
        for payload in start {
            for event in try accumulator.consume(payload) {
                if case .content(.blockStarted(_, let block)) = event { blocks.append(block) }
            }
        }
        _ = try accumulator.consume(#"""
            {"type":"response.completed","response":{"output":[
            {"id":"reasoning-item","type":"reasoning","encrypted_content":"opaque"},
            {"id":"message-item","type":"message","content":[{"type":"output_text","text":"Correct final"}]}]}}
            """#)
        let final = try #require(try accumulator.response().message)
        #expect(final.blocks.map(\.id) == blocks.reversed().map(\.id))
        #expect(final.text == "Correct final")
    }

    @Test func aStopReasonWithoutAnthropicMessageStopIsStillInterrupted() throws {
        let accumulator = AgentWireAccumulator(format: .anthropic)
        for payload in [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"lookup","input":{}}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#
        ] { _ = try accumulator.consume(payload) }
        #expect(throws: AgentWireError.incompleteStream) { try accumulator.response() }
    }

    @Test func wirePayloadLimitIsExplicitAndSticky() {
        let accumulator = AgentWireAccumulator(format: .openAI)
        #expect(throws: AgentWireError.bufferLimit) { try accumulator.consume(String(repeating: "x", count: 8 * 1_024 * 1_024 + 1)) }
        #expect(throws: AgentWireError.bufferLimit) { try accumulator.response() }
    }

    @Test func indexedChatCallsStayInProviderOrderWhenFragmentsArriveOutOfOrder() throws {
        let accumulator = AgentWireAccumulator(format: .openAI)
        _ = try accumulator.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"second","function":{"name":"lookup","arguments":"{}"}}]}}]}"#)
        _ = try accumulator.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"first","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#)
        #expect(try accumulator.response().toolCalls.map(\.id) == ["first", "second"])
    }

}

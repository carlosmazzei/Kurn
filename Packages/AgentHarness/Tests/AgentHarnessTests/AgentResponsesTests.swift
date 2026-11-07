import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentResponsesTests {
    let added = #"{"type":"response.output_item.added","output_index":1,"item":{"id":"item-1","type":"function_call","call_id":"call-1","name":"search","arguments":""}}"#
    let done = #"{"type":"response.output_item.done","output_index":1,"item":{"id":"item-1","type":"function_call","call_id":"call-1","name":"search","arguments":"{\"query\":\"Alice\"}","status":"completed"}}"#
    let completed = #"{"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":3}}}"#

    @Test func requestEncodesHistoryToolsAndPrivacy() throws {
        let request = AgentWireRequestTests().request()
        let body = AgentWireFormat.openAIResponses.requestBody(request, model: "gpt-test", reasoningEffort: "low")
        #expect(try JSONValue.parse(body.encodedString()) == body)
        #expect(body["instructions"] == .string("Ground answers"))
        #expect(body["model"] == .string("gpt-test"))
        #expect(body["max_output_tokens"] == .number(123))
        #expect(body["store"] == .bool(false))
        #expect(body["stream"] == .bool(true))
        #expect(body["reasoning"]["effort"] == .string("low"))
        #expect(body["reasoning_effort"] == .null)
        #expect(body["messages"] == .null)
        let input = body["input"].array
        #expect(input.count == 7)
        #expect(input[0] == .object(["role": .string("user"), "content": .string("Find Alice")]))
        #expect(input[1] == .object(["role": .string("assistant"), "content": .string("Searching")]))
        #expect(input[2] == .object(["type": .string("function_call"), "call_id": .string("call-1"),
                                    "name": .string("search"), "arguments": .string(#"{"query":"Alice"}"#)]))
        #expect(input[4] == .object(["type": .string("function_call_output"), "call_id": .string("call-1"),
                                    "output": .string("meeting-7 [12:34]")]))
        #expect(input[5]["output"] == .string("Not found"))
        #expect(input[6]["content"] == .string("Done"))
        #expect(body["tools"].array == [.object(["type": .string("function"), "name": .string("search"),
            "description": .string("Search meetings"), "parameters": AgentWireRequestTests().schema])])
        let noReasoning = AgentWireFormat.openAIResponses.requestBody(request, model: "new-model")
        #expect(noReasoning["reasoning"] == .null)
        let onlyCall = AgentTurnRequest(systemPrompt: "", messages: [.assistant(text: "", toolCalls: [agentCall()])],
                                        tools: [], maxOutputTokens: 1)
        #expect(AgentWireFormat.openAIResponses.requestBody(onlyCall, model: "test")["input"].array.count == 1)
    }

    @Test func textDeltasTerminalAndUsage() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        #expect(try accumulator.consume(#"{"type":"response.output_text.delta","delta":"Hello"}"#) == [.textDelta("Hello")])
        #expect(try accumulator.consume(#"{"type":"response.output_text.delta","delta":""}"#).isEmpty)
        _ = try accumulator.consume(completed)
        #expect(try accumulator.response() == AgentTurnResponse(text: "Hello", usage: AgentUsage(inputTokens: 12, outputTokens: 3)))
        #expect(try accumulator.consume(#"{"type":"response.output_text.delta","delta":"ignored"}"#).isEmpty)
    }

    @Test(arguments: [false, true]) func functionCallDeltasAndFinalSnapshots(useDoneItem: Bool) throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(added)
        _ = try accumulator.consume(#"{"type":"response.function_call_arguments.delta","item_id":"item-1","delta":"{\"query\":"}"#)
        _ = try accumulator.consume(#"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"\"Alice\"}"}"#)
        _ = try accumulator.consume(#"{"type":"response.function_call_arguments.done","item_id":"item-1","arguments":"{\"query\":\"Alice\"}"}"#)
        if useDoneItem { _ = try accumulator.consume(done) }
        _ = try accumulator.consume(completed)
        let response = try accumulator.response()
        #expect(response.stopReason == .toolUse)
        #expect(response.toolCalls == [AgentToolCall(id: "call-1", name: "search", arguments: .object(["query": .string("Alice")]),
                                                    rawArguments: #"{"query":"Alice"}"#)])
    }

    @Test func completedOutputReconcilesMultipleCallsWithoutDuplicatingThem() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(added)
        _ = try accumulator.consume(done)
        _ = try accumulator.consume(#"""
            {"type":"response.completed","response":{"output":[{"type":"reasoning"},
            {"type":"function_call","call_id":"call-1","name":"search","arguments":"{}"},
            {"type":"function_call","call_id":"call-2","name":"read","arguments":"{}"}]}}
            """#)
        let response = try accumulator.response()
        #expect(response.toolCalls.map(\.id) == ["call-1", "call-2"])
        #expect(response.usage == nil)
    }

    @Test(arguments: ["content_filter", "unknown"]) func incompleteOtherReasonsFail(reason: String) throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        let payload = #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"\#(reason)"}}}"#
        #expect(throws: AgentWireError.remote("Incomplete response: \(reason)")) { try accumulator.consume(payload) }
        #expect(throws: AgentWireError.self) { try accumulator.response() }
    }

    @Test(arguments: [
        #"{"type":"response.failed","response":{"error":{"message":"Failed"}}}"#,
        #"{"type":"error","message":"Failed"}"#
    ]) func remoteFailuresFail(payload: String) {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        #expect(throws: AgentWireError.remote("Failed")) { try accumulator.consume(payload) }
        #expect(throws: AgentWireError.remote("Failed")) { try accumulator.response() }
    }

    @Test(arguments: ["missing-done", "missing-id", "missing-name", "incomplete-status"])
    func incompleteCallsCannotEscape(kind: String) throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(added)
        if kind != "missing-done" {
            var payload = done
            if kind == "missing-id" { payload = payload.replacingOccurrences(of: "call-1", with: "") }
            if kind == "missing-name" { payload = payload.replacingOccurrences(of: "search", with: "") }
            if kind == "incomplete-status" { payload = payload.replacingOccurrences(of: "completed", with: "incomplete") }
            _ = try accumulator.consume(payload)
        }
        _ = try accumulator.consume(completed)
        #expect(throws: AgentWireError.incompleteToolCall) { try accumulator.response() }
    }

    @Test func invalidArgumentsStayRecoverableAndKeepRawText() throws {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        _ = try accumulator.consume(done.replacingOccurrences(of: "{\\\"query\\\":\\\"Alice\\\"}", with: "{bad"))
        _ = try accumulator.consume(completed)
        #expect(try accumulator.response().toolCalls.first?.arguments == .null)
        #expect(try accumulator.response().toolCalls.first?.rawArguments == "{bad")
    }
}

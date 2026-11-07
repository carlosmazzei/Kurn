import Foundation
import Testing
@testable import KurnCore

@Suite struct AgentWireRequestTests {
    let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["query": .object(["type": .string("string")])])])

    func request(metadata: JSONValue? = nil) -> AgentTurnRequest {
        let call = AgentToolCall(id: "call-1", name: "search", arguments: .object(["query": .string("Alice")]),
                                 rawArguments: #"{"query":"Alice"}"#, providerMetadata: metadata)
        return AgentTurnRequest(systemPrompt: "Ground answers", messages: [
            .user("Find Alice"), .assistant(text: "Searching", toolCalls: [call, agentCall("call-2", name: "read")]),
            .toolResult(callID: "call-1", toolName: "search", content: "meeting-7 [12:34]", isError: false),
            .toolResult(callID: "call-2", toolName: "read", content: "Not found", isError: true),
            .assistant(text: "Done", toolCalls: [])
        ], tools: [AgentToolSpec(name: "search", description: "Search meetings", inputSchema: schema)], maxOutputTokens: 123)
    }

    @Test func openAIRequest() throws {
        let body = AgentWireFormat.openAI.requestBody(request(), model: "gpt-test", reasoningEffort: "low")
        #expect(try JSONValue.parse(body.encodedString()) == body)
        #expect(body["model"] == .string("gpt-test"))
        #expect(body["max_completion_tokens"] == .number(123))
        #expect(body["stream"] == .bool(true))
        #expect(body["stream_options"]["include_usage"] == .bool(true))
        #expect(body["reasoning_effort"] == .string("low"))
        let messages = body["messages"].array
        #expect(messages.count == 6)
        #expect(messages[0] == .object(["role": .string("system"), "content": .string("Ground answers")]))
        #expect(messages[1]["role"] == .string("user"))
        #expect(messages[2]["content"] == .string("Searching"))
        let call = try #require(messages[2]["tool_calls"].array.first)
        #expect(call["id"] == .string("call-1"))
        #expect(call["type"] == .string("function"))
        #expect(call["function"]["name"] == .string("search"))
        #expect(call["function"]["arguments"] == .string(#"{"query":"Alice"}"#))
        #expect(messages[3] == .object(["role": .string("tool"), "tool_call_id": .string("call-1"),
                                       "content": .string("meeting-7 [12:34]")]))
        #expect(messages[5]["tool_calls"] == .null)
        #expect(body["tools"].array.first?["function"]["parameters"] == schema)
        let legacy = AgentWireFormat.openAI.requestBody(request(), model: "custom", openAITokenField: "max_tokens")
        #expect(legacy["max_tokens"] == .number(123))
        #expect(legacy["max_completion_tokens"] == .null)
        #expect(legacy["reasoning_effort"] == .null)
    }

    @Test func anthropicRequestGroupsResults() {
        let body = AgentWireFormat.anthropic.requestBody(request(), model: "claude-test")
        #expect(body["system"] == .string("Ground answers"))
        #expect(body["model"] == .string("claude-test"))
        #expect(body["max_tokens"] == .number(123))
        #expect(body["stream"] == .bool(true))
        let messages = body["messages"].array
        #expect(messages.count == 4)
        #expect(messages[0]["content"].array.first?["text"] == .string("Find Alice"))
        let blocks = messages[1]["content"].array
        #expect(blocks.count == 3)
        #expect(blocks[0]["text"] == .string("Searching"))
        #expect(blocks[1] == .object(["type": .string("tool_use"), "id": .string("call-1"),
                                     "name": .string("search"), "input": .object(["query": .string("Alice")])]))
        let results = messages[2]["content"].array
        #expect(messages[2]["role"] == .string("user"))
        #expect(results.count == 2)
        #expect(results[0]["tool_use_id"] == .string("call-1"))
        #expect(results[0]["is_error"] == .bool(false))
        #expect(results[1]["is_error"] == .bool(true))
        #expect(body["tools"].array.first?["input_schema"] == schema)
    }

    @Test func geminiRequestMapsIDsAndSignatures() throws {
        let metadata: JSONValue = .object(["geminiID": .string("wire-id"), "thoughtSignature": .string("opaque-signature")])
        let body = AgentWireFormat.gemini.requestBody(request(metadata: metadata), model: "gemini-test")
        #expect(body["systemInstruction"]["parts"].array.first?["text"] == .string("Ground answers"))
        #expect(body["generationConfig"]["maxOutputTokens"] == .number(123))
        #expect(body["stream"] == .null)
        let contents = body["contents"].array
        #expect(contents.count == 4)
        #expect(contents[1]["role"] == .string("model"))
        let part = contents[1]["parts"].array[1]
        #expect(part["thoughtSignature"] == .string("opaque-signature"))
        #expect(part["functionCall"] == .object(["id": .string("wire-id"), "name": .string("search"),
                                               "args": .object(["query": .string("Alice")])]))
        let results = contents[2]["parts"].array
        #expect(results.count == 2)
        #expect(results[0]["functionResponse"] == .object(["name": .string("search"), "id": .string("wire-id"),
            "response": .object(["result": .string("meeting-7 [12:34]")])]))
        #expect(results[1]["functionResponse"]["id"] == .null)
        #expect(results[1]["functionResponse"]["response"]["error"] == .string("Not found"))
        #expect(body["tools"].array.first?["functionDeclarations"].array.first?["parameters"] == schema)
        let call = AgentToolCall(id: "1", name: "search", arguments: .object([:]), rawArguments: "{}", providerMetadata: metadata)
        #expect(try JSONDecoder().decode(AgentToolCall.self, from: JSONEncoder().encode(call)) == call)
        let legacy = #"{"id":"1","name":"search","arguments":{},"rawArguments":"{}"}"#
        #expect(try JSONDecoder().decode(AgentToolCall.self, from: Data(legacy.utf8)).providerMetadata == nil)
    }

    @Test(arguments: AgentWireFormat.allCases) func emptyRequestHasNoTools(format: AgentWireFormat) throws {
        let request = AgentTurnRequest(systemPrompt: "", messages: [], tools: [], maxOutputTokens: 1)
        let body = format.requestBody(request, model: "model")
        #expect(body["tools"] == .null)
        #expect(try JSONValue.parse(body.encodedString()) == body)
    }

    @Test func toolOnlyAssistantAndFallbackName() {
        let request = AgentTurnRequest(systemPrompt: "", messages: [
            .assistant(text: "", toolCalls: [agentCall()]),
            .toolResult(callID: "1", toolName: "wrong-name", content: "found", isError: false),
            .toolResult(callID: "unknown-id", toolName: "fallback", content: "found", isError: false)
        ], tools: [], maxOutputTokens: 1)
        let gemini = AgentWireFormat.gemini.requestBody(request, model: "model")["contents"].array
        #expect(gemini[0]["parts"].array.count == 1)
        #expect(gemini[1]["parts"].array[0]["functionResponse"]["name"] == .string("lookup"))
        #expect(gemini[1]["parts"].array[1]["functionResponse"]["name"] == .string("fallback"))
        let anthropic = AgentWireFormat.anthropic.requestBody(request, model: "model")["messages"].array
        #expect(anthropic[0]["content"].array.count == 1)
    }
}

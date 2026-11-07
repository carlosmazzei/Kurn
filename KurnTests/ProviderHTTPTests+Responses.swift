import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {
    @Test(arguments: ["gpt-5.4", "gpt-6.1-terra"])
    func responsesToolCallRoundTrip(model: String) async throws {
        let first = #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item","call_id":"call-1","name":"search","arguments":""}}"#
        let arguments = #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}"#
        let done = #"{"type":"response.function_call_arguments.done","output_index":0,"arguments":"{}"}"#
        let terminal = #"{"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2}}}"#
        let reasoning = #"""
            {"type":"response.output_item.done","output_index":1,"item":{"type":"reasoning","id":"rs_1",
            "summary":[],"encrypted_content":"encrypted"}}
            """#
        let answer = #"{"type":"response.output_text.delta","delta":"Found Alice"}"#
        MockURLProtocol.enqueue([
            .success(status: 200, body: sseBody([reasoning, first, arguments, done, terminal]), headers: [:]),
            .success(status: 200, body: sseBody([answer, terminal]), headers: [:])
        ])
        let provider = OpenAIProvider(apiKey: "test-key", model: model, session: MockURLProtocol.session())
        let tools = [AgentToolSpec(name: "search", description: "Search", inputSchema: .object(["type": .string("object")]))]
        let firstRequest = AgentTurnRequest(systemPrompt: "Ground answers", messages: [.user("Find Alice")],
                                           tools: tools, maxOutputTokens: 300)
        let response = try await provider.streamTurn(firstRequest) { _ in }
        let request = try #require(MockURLProtocol.lastRequest)
        let body = try JSONValue.parse(String(decoding: MockURLProtocol.body(of: request), as: UTF8.self))
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(body["store"] == .bool(false))
        #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
        #expect(body["reasoning_effort"] == .null)
        #expect(body["reasoning"] == (model.hasPrefix("gpt-5") ? .object(["effort": .string("low")]) : .null))
        #expect(body["tools"].array.first?["type"] == .string("function"))
        #expect(body["tools"].array.first?["parameters"]["type"] == .string("object"))
        #expect(response.toolCalls.first?.id == "call-1")
        let nextRequest = AgentTurnRequest(systemPrompt: "Ground answers", messages: firstRequest.messages + [
            .assistant(text: response.text, toolCalls: response.toolCalls, providerMetadata: response.providerMetadata),
            .toolResult(callID: "call-1", toolName: "search", content: "Alice in meeting A", isError: false)
        ], tools: tools, maxOutputTokens: 300)
        let final = try await provider.streamTurn(nextRequest) { _ in }
        #expect(final.text == "Found Alice")
        #expect(final.usage == AgentUsage(inputTokens: 10, outputTokens: 2))
        let followup = try #require(MockURLProtocol.lastRequest)
        let replay = try JSONValue.parse(String(decoding: MockURLProtocol.body(of: followup), as: UTF8.self))["input"].array
        #expect(replay[1]["type"] == .string("reasoning"))
        #expect(replay[1]["encrypted_content"] == .string("encrypted"))
        #expect(replay[2]["type"] == .string("function_call"))
        #expect(replay[2]["call_id"] == .string("call-1"))
        #expect(replay[2]["arguments"] == .string("{}"))
        #expect(replay[2]["id"] == .null)
        #expect(replay[3] == .object(["type": .string("function_call_output"), "call_id": .string("call-1"),
                                    "output": .string("Alice in meeting A")]))
    }

    @Test(arguments: ["id", "host"])
    func responsesRequiresBuiltInIdentityAndOfficialOrigin(mismatch: String) async throws {
        var selected = AIProvider.openAI
        switch mismatch {
        case "id": selected.id = "custom"
        default: selected.baseURLString = "https://api.openai.com.example/v1"
        }
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody([
            #"{"choices":[{"delta":{"content":"Hello"},"finish_reason":"stop"}]}"#
        ]), headers: [:])])
        let provider = OpenAIProvider(provider: selected, apiKey: "test", model: "gpt-6.1-terra", session: MockURLProtocol.session())
        let request = AgentTurnRequest(systemPrompt: "sys", messages: [.user("Hi")], tools: [], maxOutputTokens: 10)
        let response = try await provider.streamTurn(request) { _ in }
        #expect(response.text == "Hello")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/v1/chat/completions")
    }

    @Test(arguments: [
        #"{"type":"response.failed","response":{"error":{"message":"Failed"}}}"#,
        #"{"type":"error","message":"Failed"}"#,
        #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}"#
    ])
    func responsesErrorsUseExistingMapping(payload: String) async throws {
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody([payload]), headers: [:])])
        let provider = OpenAIProvider(apiKey: "test", session: MockURLProtocol.session())
        let request = AgentTurnRequest(systemPrompt: "sys", messages: [.user("Hi")], tools: [], maxOutputTokens: 10)
        do {
            _ = try await provider.streamTurn(request) { _ in }
            Issue.record("Expected API error")
        } catch let AppError.apiError(statusCode, _) {
            #expect(statusCode == 0)
        }
    }
}

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
        let reasoning = try JSONValue.parse(#"""
            {"type":"response.output_item.done","output_index":1,"item":{"type":"reasoning","id":"rs_1",
            "summary":[],"encrypted_content":"encrypted"}}
            """#).encodedString()
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
        let json = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request))
        let body = try #require(json as? [String: Any])
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(body["store"] as? Bool == false)
        #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
        #expect(body["reasoning_effort"] == nil)
        if model.hasPrefix("gpt-5") {
            #expect(body["reasoning"] as? [String: String] == ["effort": "low"])
        } else {
            #expect(body["reasoning"] == nil)
        }
        let specs = body["tools"] as? [[String: Any]]
        #expect(specs?.first?["type"] as? String == "function")
        #expect((specs?.first?["parameters"] as? [String: String])?["type"] == "object")
        #expect(response.toolCalls.first?.id == "call-1")
        let nextRequest = AgentTurnRequest(systemPrompt: "Ground answers", messages: firstRequest.messages + [
            .assistant(text: response.text, toolCalls: response.toolCalls, providerMetadata: response.providerMetadata),
            .toolResult(callID: "call-1", toolName: "search", content: "Alice in meeting A", isError: false)
        ], tools: tools, maxOutputTokens: 300)
        let final = try await provider.streamTurn(nextRequest) { _ in }
        #expect(final.text == "Found Alice")
        #expect(final.usage == AgentUsage(inputTokens: 10, outputTokens: 2))
        let followup = try #require(MockURLProtocol.lastRequest)
        let followupJSON = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: followup)) as? [String: Any]
        let replay = try #require(followupJSON?["input"] as? [[String: Any]])
        try #require(replay.count == 4)
        #expect(replay[1]["type"] as? String == "reasoning")
        #expect(replay[1]["encrypted_content"] as? String == "encrypted")
        #expect(replay[2]["type"] as? String == "function_call")
        #expect(replay[2]["call_id"] as? String == "call-1")
        #expect(replay[2]["arguments"] as? String == "{}")
        #expect(replay[2]["id"] == nil)
        #expect(replay[3] as? [String: String] == ["type": "function_call_output", "call_id": "call-1", "output": "Alice in meeting A"])
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

    @Test(arguments: [false, true])
    func responsesRefusalIsAnAssistantReply(streamed: Bool) async throws {
        var payloads: [String] = []
        if streamed { payloads.append(#"{"type":"response.refusal.delta","delta":"I cannot help."}"#) }
        payloads.append(try JSONValue.parse(#"""
            {"type":"response.completed","response":{"output":[{"type":"message","content":[
            {"type":"refusal","refusal":"I cannot help."}]}]}}
            """#).encodedString())
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody(payloads), headers: [:])])
        let provider = OpenAIProvider(apiKey: "test", session: MockURLProtocol.session())
        let request = AgentTurnRequest(systemPrompt: "sys", messages: [.user("Hi")], tools: [], maxOutputTokens: 10)
        let text = StreamingAccumulator()
        let response = try await provider.streamTurn(request) { event in
            if case .textDelta(let delta) = event { text.append(delta) }
        }
        #expect(text.value == "I cannot help.")
        #expect(response.text == "I cannot help.")
        #expect(response.stopReason == .endTurn)
    }
}

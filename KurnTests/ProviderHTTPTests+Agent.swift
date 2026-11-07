import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

private enum AgentTestVendor: String, CaseIterable {
    case openAI, compatible, anthropic, google

    var provider: AIProvider {
        switch self {
        case .openAI: return .openAI
        case .compatible:
            return AIProvider(id: "custom-agent", displayName: "Custom", kind: .openAICompatible,
                              baseURLString: "https://custom.example/v1", defaultModel: "custom-model")
        case .anthropic: return .anthropic
        case .google: return .google
        }
    }

    func model(key: String = "test-key", invalidURL: Bool = false) -> any AgentModel {
        var selected = provider
        if invalidURL { selected.baseURLString = "not a URL" }
        switch self {
        case .openAI, .compatible:
            return OpenAIProvider(provider: selected, apiKey: key, model: "gpt-5.4", session: MockURLProtocol.session())
        case .anthropic:
            return AnthropicProvider(provider: selected, apiKey: key, model: "claude-test", session: MockURLProtocol.session())
        case .google:
            return GoogleProvider(provider: selected, apiKey: key, model: "models/gemini-test", session: MockURLProtocol.session())
        }
    }

    var toolPayload: String {
        switch self {
        case .openAI, .compatible:
            return #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"search","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        case .anthropic:
            return #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c1","name":"search","input":{}}}"#
        case .google:
            return #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"search","args":{}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}"#
        }
    }

    var textPayload: String {
        switch self {
        case .openAI, .compatible: return #"{"choices":[{"delta":{"content":"Hello"},"finish_reason":"stop"}]}"#
        case .anthropic: return #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#
        case .google: return #"{"candidates":[{"content":{"parts":[{"text":"Hello"}]},"finishReason":"STOP"}]}"#
        }
    }
}

extension ProviderHTTPTests {
    private var agentRequest: AgentTurnRequest {
        AgentTurnRequest(systemPrompt: "Ground answers", messages: [.user("Find Alice")],
                         tools: [AgentToolSpec(name: "search", description: "Search meetings", inputSchema: .object([:]))],
                         maxOutputTokens: 321)
    }

    @Test(arguments: AgentTestVendor.allCases)
    private func agentToolOnlyTurnUsesVendorRoute(vendor: AgentTestVendor) async throws {
        var payloads = [vendor.toolPayload]
        if vendor == .anthropic {
            payloads += [#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":10,"output_tokens":2}}"#]
        }
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody(payloads), headers: [:])])
        let response = try await vendor.model().streamTurn(agentRequest) { _ in }
        #expect(response.text.isEmpty)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "search")
        #expect(response.toolCalls[0].arguments == .object([:]))
        #expect(response.stopReason == .toolUse)
        #expect(response.usage == AgentUsage(inputTokens: 10, outputTokens: 2))
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.timeoutInterval == LLMHTTP.chatTimeout)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["tools"] != nil)
        switch vendor {
        case .openAI, .compatible:
            #expect(request.url?.absoluteString == vendor.provider.baseURLString + "/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(body?["max_completion_tokens"] as? Int == 321)
            #expect(body?["reasoning_effort"] as? String == (vendor == .openAI ? "low" : nil))
            #expect(body?["stream"] as? Bool == true)
        case .anthropic:
            #expect(request.url?.path == "/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(body?["max_tokens"] as? Int == 321)
            #expect(body?["stream"] as? Bool == true)
        case .google:
            #expect(request.url?.path == "/v1beta/models/gemini-test:streamGenerateContent")
            #expect(request.url?.query == "alt=sse")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
            #expect(body?["systemInstruction"] != nil)
            #expect((body?["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 321)
        }
    }

    @Test(arguments: AgentTestVendor.allCases, [false, true])
    private func agentTextDeltasAreForwarded(vendor: AgentTestVendor, outputLimited: Bool) async throws {
        var payload = vendor.textPayload
        if outputLimited {
            payload = payload.replacingOccurrences(of: "\"stop\"", with: "\"length\"")
                .replacingOccurrences(of: "\"STOP\"", with: "\"MAX_TOKENS\"")
        }
        var payloads = ["malformed", payload]
        if vendor == .anthropic {
            let reason = outputLimited ? "max_tokens" : "end_turn"
            payloads.append(#"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"}}"#)
        }
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody(payloads), headers: [:])])
        let text = StreamingAccumulator()
        let response = try await vendor.model().streamTurn(agentRequest) { event in
            if case .textDelta(let delta) = event { text.append(delta) }
        }
        #expect(text.value == "Hello")
        #expect(response.text == "Hello")
        #expect(response.toolCalls.isEmpty)
        #expect(response.stopReason == (outputLimited ? .maxTokens : .endTurn))
    }

    @Test(arguments: ["empty", "remote", "incomplete", "interrupted", "http", "transport"])
    func agentStreamErrorsAreMappedAndNeverRetried(kind: String) async {
        let stub: MockURLProtocol.Stub
        switch kind {
        case "empty": stub = .success(status: 200, body: sseBody(["malformed"]), headers: [:])
        case "remote": stub = .success(status: 200, body: sseBody([#"{"error":{"message":"Overloaded"}}"#]), headers: [:])
        case "incomplete":
            stub = .success(status: 200, body: sseBody([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"search"}}]},"finish_reason":"tool_calls"}]}"#
            ]), headers: [:])
        case "interrupted":
            stub = .success(status: 200, body: sseBody([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"search","arguments":"{}"}}]}}]}"#
            ]), headers: [:])
        case "http": stub = .success(status: 503, body: Data("Unavailable".utf8), headers: [:])
        default: stub = .failure(URLError(.timedOut))
        }
        MockURLProtocol.enqueue([stub])
        do {
            _ = try await AgentTestVendor.openAI.model().streamTurn(agentRequest) { _ in }
            Issue.record("Expected stream error")
        } catch {
            if kind == "empty" || kind == "incomplete" {
                guard case AppError.decodingError = error else { Issue.record("Expected decoding error"); return }
            } else if kind == "interrupted" {
                guard case AppError.networkError(let urlError) = error else { Issue.record("Expected transport error"); return }
                #expect(urlError.code == .networkConnectionLost)
            } else if kind != "transport" {
                guard case AppError.apiError = error else { Issue.record("Expected API error"); return }
            }
        }
        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test(arguments: AgentTestVendor.allCases)
    private func agentRejectsMissingKeyAndInvalidURL(vendor: AgentTestVendor) async {
        await #expect(throws: AppError.self) { try await vendor.model(key: "").streamTurn(agentRequest) { _ in } }
        await #expect(throws: AppError.self) { try await vendor.model(invalidURL: true).streamTurn(agentRequest) { _ in } }
    }
}

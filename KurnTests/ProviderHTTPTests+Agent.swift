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
        case .openAI:
            return #"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"c1","name":"search","arguments":"{}"}}"#
        case .compatible:
            return #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"search","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        case .anthropic:
            return #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c1","name":"search","input":{}}}"#
        case .google:
            return #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"search","args":{}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}"#
        }
    }

    var textPayload: String {
        switch self {
        case .openAI: return #"{"type":"response.output_text.delta","delta":"Hello"}"#
        case .compatible: return #"{"choices":[{"delta":{"content":"Hello"},"finish_reason":"stop"}]}"#
        case .anthropic: return #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#
        case .google: return #"{"candidates":[{"content":{"parts":[{"text":"Hello"}]},"finishReason":"STOP"}]}"#
        }
    }
}

extension ProviderHTTPTests {
    @Test func agentResponsesMinimumOutputIsReported() async throws {
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody([
            AgentTestVendor.openAI.textPayload, #"{"type":"response.completed","response":{}}"#
        ]), headers: [:])])
        let request = AgentTurnRequest(systemPrompt: "System", messages: [.user("Question")], tools: [], maxOutputTokens: 1)
        let events = AsyncStream<AgentModelEvent>.makeStream()
        _ = try await AgentTestVendor.openAI.model().streamTurn(request) { events.continuation.yield($0) }
        events.continuation.finish()
        var received: [AgentModelEvent] = []
        for await event in events.stream { received.append(event) }
        #expect(received.filter { if case .content = $0 { return false }; return true } == [.outputBudgetAdjusted(requested: 1, sent: 16), .textDelta("Hello")])
        #expect(received.filter { if case .content(.messageFinished) = $0 { return true }; return false }.count == 1)
        let http = try #require(MockURLProtocol.lastRequest)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: http)) as? [String: Any]
        #expect(body?["max_output_tokens"] as? Int == 16)
    }

    private var agentRequest: AgentTurnRequest {
        AgentTurnRequest(systemPrompt: "Ground answers", messages: [.user("Find Alice")],
                         tools: [AgentToolSpec(name: "search", description: "Search meetings", inputSchema: .object([:]))],
                         maxOutputTokens: 321)
    }

    @Test(arguments: AgentTestVendor.allCases)
    private func agentToolOnlyTurnUsesVendorRoute(vendor: AgentTestVendor) async throws {
        var payloads = [vendor.toolPayload]
        if vendor == .openAI {
            payloads += [#"{"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2}}}"#]
        }
        if vendor == .anthropic {
            payloads += [#"{"type":"content_block_stop","index":0}"#]
            payloads += [#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":10,"output_tokens":2}}"#,
                         #"{"type":"message_stop"}"#]
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
        case .openAI:
            #expect(request.url?.path == "/v1/responses")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(body?["max_output_tokens"] as? Int == 321)
            #expect(body?["store"] as? Bool == false)
            #expect(body?["reasoning_effort"] == nil)
            #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "low")
            #expect(body?["instructions"] as? String == "Ground answers")
            #expect(body?["input"] != nil)
            let tools = body?["tools"] as? [[String: Any]]
            #expect(tools?.first?["name"] as? String == "search")
            #expect(tools?.first?["function"] == nil)
        case .compatible:
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
        var payloads = [payload]
        if vendor == .openAI {
            payloads.append(outputLimited
                ? #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
                : #"{"type":"response.completed","response":{}}"#)
        }
        if vendor == .anthropic {
            let reason = outputLimited ? "max_tokens" : "end_turn"
            payloads.append(#"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"}}"#)
            payloads.append(#"{"type":"message_stop"}"#)
        }
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody(payloads), headers: [:])])
        let text = StreamingAccumulator()
        let identity = AgentRequestIdentity()
        let response = try await vendor.model().streamTurn(agentRequest.identified(identity)) { event in
            if case .textDelta(let delta) = event { text.append(delta) }
        }
        #expect(response.message?.identity?.requestID == identity.id)
        #expect(vendor.model().descriptor?.api == response.message?.identity?.api)
        #expect(text.value == "Hello")
        #expect(response.text == "Hello")
        #expect(response.toolCalls.isEmpty)
        #expect(response.stopReason == (outputLimited ? .maxTokens : .endTurn))
    }

    @Test(arguments: ["empty", "malformed", "remote", "incomplete", "interrupted", "http", "transport"])
    func agentStreamErrorsAreMappedAndNeverRetried(kind: String) async {
        let stub: MockURLProtocol.Stub
        switch kind {
        case "empty": stub = .success(status: 200, body: Data(), headers: [:])
        case "malformed": stub = .success(status: 200, body: sseBody(["malformed"]), headers: [:])
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
            _ = try await AgentTestVendor.compatible.model().streamTurn(agentRequest) { _ in }
            Issue.record("Expected stream error")
        } catch {
            if kind == "empty" || kind == "incomplete" || kind == "malformed" {
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
        for model in [vendor.model(key: ""), vendor.model(invalidURL: true)] {
            let events = AsyncStream<AgentModelEvent>.makeStream()
            await #expect(throws: AppError.self) { try await model.streamTurn(agentRequest) { events.continuation.yield($0) } }
            events.continuation.finish()
            var received: [AgentModelEvent] = []
            for await event in events.stream { received.append(event) }
            #expect(received == [.content(.failed(.preparation))])
        }
    }
    @Test func hostClassifiesProtocolAndCancellationFailures() {
        #expect(LLMHTTP.agentStreamFailure(AppError.decodingError("private")) == .invalidStream)
        #expect(LLMHTTP.agentStreamFailure(AppError.networkError(URLError(.cancelled))) == .cancelled)
        #expect(LLMHTTP.agentStreamFailure(AppError.networkError(URLError(.timedOut))) == .transport)
        #expect(LLMHTTP.agentStreamFailure(CancellationError()) == .cancelled)
        #expect(LLMHTTP.agentStreamFailure(AppError.apiError(statusCode: 500, message: "private")) == .transport)
    }

    @Test func agentFinalCorrectsStreamedDraftAndReplayChangesAreTraced() async throws {
        let thought = AgentContentBlock(id: "thought", content: .thinking(text: "private", signature: "opaque", redacted: false))
        let prior = try AgentContentMessage(id: "prior", timestampMilliseconds: 123, role: .assistant, blocks: [thought],
            identity: AgentResponseIdentity(api: "anthropic", model: "other", requestID: "prior-request"), stopReason: .endTurn)
        let request = AgentTurnRequest(systemPrompt: "", messages: [.content(prior), .user("Question")], tools: [], maxOutputTokens: 32)
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody([
            #"{"type":"response.output_text.delta","delta":"Wrong draft"}"#,
            #"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Correct final"}]}],"usage":{"input_tokens":12,"output_tokens":3}}}"#
        ]), headers: [:])])
        let events = AsyncStream<AgentModelEvent>.makeStream()
        let response = try await AgentTestVendor.openAI.model().streamTurn(request) { events.continuation.yield($0) }
        events.continuation.finish()
        var observed: [AgentModelEvent] = []
        for await event in events.stream { observed.append(event) }
        #expect(response.text == "Correct final" && response.message?.usage == AgentUsage(inputTokens: 12, outputTokens: 3))
        #expect(observed.filter { if case .content(.messageFinished) = $0 { return true }; return false }.count == 1)
        #expect(observed.contains { if case .replayAdjusted(let facts) = $0 { return facts.omittedThinkingBlocks == 1 }; return false })
        let http = try #require(MockURLProtocol.lastRequest)
        let body = String(decoding: MockURLProtocol.body(of: http), as: UTF8.self)
        #expect(!body.contains("private") && body.contains("Thinking omitted"))
    }

}

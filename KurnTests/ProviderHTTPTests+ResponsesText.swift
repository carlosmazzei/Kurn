import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {
    func responseJSON(_ text: String, truncated: Bool = false, refusal: Bool = false) -> [String: Any] {
        var response: [String: Any] = [
            "status": truncated ? "incomplete" : "completed",
            "output": [["type": "message", "content": [["type": refusal ? "refusal" : "output_text", refusal ? "refusal" : "text": text]]]]
        ]
        if truncated { response["incomplete_details"] = ["reason": "max_output_tokens"] }
        return response
    }

    @Test(arguments: ["summary", "streamSummary", "chat"])
    func compatibleTextRoutesRetainChatCompletions(route: String) async throws {
        let provider = OpenAIProvider(provider: AIProvider(id: "custom", displayName: "Custom", kind: .openAICompatible,
            baseURLString: "https://custom.example/v1", defaultModel: "gpt-5.4"),
            apiKey: "test", model: "gpt-5.4", session: MockURLProtocol.session())
        if route.hasPrefix("stream") {
            MockURLProtocol.enqueue([.success(status: 200, body: sseBody([
                #"{"choices":[{"delta":{"content":"Recap\nHello"},"finish_reason":"stop"}]}"#
            ]), headers: [:])])
        } else {
            MockURLProtocol.enqueue([MockURLProtocol.json(["choices": [["message": ["content": "## Recap\nHello"]]]])])
        }
        switch route {
        case "summary": _ = try await provider.summarize(systemPrompt: "sys", userPrompt: "usr")
        case "streamSummary": _ = try await provider.streamSummary(systemPrompt: "sys", userPrompt: "usr") { _ in }
        default: _ = try await provider.chat(systemPrompt: "sys", messages: [.init(role: .user, content: "usr")])
        }
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://custom.example/v1/chat/completions")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        #expect(body?["messages"] != nil)
        #expect(body?["max_completion_tokens"] != nil)
        #expect(body?["store"] == nil)
        #expect(body?["instructions"] == nil)
        #expect(body?["reasoning_effort"] == nil)
    }

    @Test(arguments: ["summary", "streamSummary", "chat"])
    func officialTextRoutesMapResponseFailures(route: String) async throws {
        let failed: [String: Any] = ["status": "failed", "error": ["message": "Unavailable"]]
        if route.hasPrefix("stream") {
            let event: [String: Any] = ["type": "response.failed", "response": failed]
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            MockURLProtocol.enqueue([.success(status: 200, body: sseBody([payload]), headers: [:])])
        } else {
            MockURLProtocol.enqueue([MockURLProtocol.json(failed)])
        }
        let provider = OpenAIProvider(apiKey: "test", session: MockURLProtocol.session())
        do {
            switch route {
            case "summary": _ = try await provider.summarize(systemPrompt: "sys", userPrompt: "usr")
            case "streamSummary": _ = try await provider.streamSummary(systemPrompt: "sys", userPrompt: "usr") { _ in }
            default: _ = try await provider.chat(systemPrompt: "sys", messages: [.init(role: .user, content: "usr")])
            }
            Issue.record("Expected response failure")
        } catch let AppError.apiError(statusCode, message) {
            #expect(statusCode == 0)
            #expect(message == "Unavailable")
        }
        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test func officialBufferedInvalidResponseIsDecodingError() async {
        MockURLProtocol.enqueue([MockURLProtocol.json(["status": "in_progress"])])
        let provider = OpenAIProvider(apiKey: "test", session: MockURLProtocol.session())
        do {
            _ = try await provider.chat(systemPrompt: "sys", messages: [])
            Issue.record("Expected decoding error")
        } catch AppError.decodingError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: ["summary", "streamSummary", "chat"])
    func responseWithoutProviderErrorUsesLocalizedDecodingError(route: String) async throws {
        let failed: [String: Any] = ["status": "failed"]
        if route.hasPrefix("stream") {
            let event: [String: Any] = ["type": "response.failed", "response": failed]
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            MockURLProtocol.enqueue([.success(status: 200, body: sseBody([payload]), headers: [:])])
        } else {
            MockURLProtocol.enqueue([MockURLProtocol.json(failed)])
        }
        let provider = OpenAIProvider(apiKey: "test", session: MockURLProtocol.session())
        do {
            switch route {
            case "summary": _ = try await provider.summarize(systemPrompt: "sys", userPrompt: "usr")
            case "streamSummary": _ = try await provider.streamSummary(systemPrompt: "sys", userPrompt: "usr") { _ in }
            default: _ = try await provider.chat(systemPrompt: "sys", messages: [])
            }
            Issue.record("Expected localized failure")
        } catch AppError.decodingError(let detail) {
            #expect(detail == NSLocalizedString("error.provider_response_invalid", comment: ""))
        }
    }

    @Test(arguments: ["interrupted", "incompleteTool"])
    func officialTextStreamRequiresCompleteTerminalOutput(kind: String) async throws {
        let payloads = kind == "interrupted"
            ? [#"{"type":"response.output_text.delta","delta":"Partial"}"#]
            : [#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","name":"read","arguments":"{}"}}"#,
               #"{"type":"response.completed","response":{}}"#]
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody(payloads), headers: [:])])
        let provider = OpenAIProvider(apiKey: "test", session: MockURLProtocol.session())
        do {
            _ = try await provider.streamSummary(systemPrompt: "sys", userPrompt: "usr") { _ in }
            Issue.record("Expected stream failure")
        } catch AppError.networkError(let error) where kind == "interrupted" {
            #expect(error.code == .networkConnectionLost)
        } catch AppError.decodingError where kind == "incompleteTool" {
        }
    }

    @Test func textStreamFallsBackToCompletedOutput() async throws {
        let text = "## Recap\nHello"
        let event: [String: Any] = ["type": "response.completed", "response": responseJSON(text)]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        MockURLProtocol.enqueue([.success(status: 200, body: sseBody([payload]), headers: [:])])
        let provider = OpenAIProvider(apiKey: "test", session: MockURLProtocol.session())
        let received = StreamingAccumulator()
        let result = try await provider.streamSummary(systemPrompt: "s", userPrompt: "u") { received.append($0) }
        #expect(result.sections.first?.title == "Recap")
        #expect(received.value == text)
    }
}

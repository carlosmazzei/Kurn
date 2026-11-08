import Foundation
import Testing
@testable import KurnCore

@Suite struct OpenAIResponsesTextTests {
    @Test func requestMapsInstructionsMessagesBudgetAndReasoning() {
        let body = OpenAIResponsesText.requestBody([
            "model": "gpt-5.4", "messages": [["role": "system", "content": "Ground answers"],
                ["role": "user", "content": "Question"], ["role": "assistant", "content": "Answer"],
                ["role": "system", "content": "Be concise"]],
            "max_tokens": 10, "max_completion_tokens": 20, "reasoning_effort": "low", "stream": true,
            "stream_options": ["include_usage": true], "store": true
        ])
        #expect(body["model"] as? String == "gpt-5.4")
        #expect(body["instructions"] as? String == "Ground answers\n\nBe concise")
        #expect(body["input"] as? [[String: String]] == [["role": "user", "content": "Question"], ["role": "assistant", "content": "Answer"]])
        #expect(body["max_output_tokens"] as? Int == 20)
        #expect(body["reasoning"] as? [String: String] == ["effort": "low"])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        for key in ["messages", "max_tokens", "max_completion_tokens", "reasoning_effort", "stream_options"] {
            #expect(body[key] == nil)
        }
        let fallback = OpenAIResponsesText.requestBody(["max_tokens": 12])
        #expect(fallback["max_output_tokens"] as? Int == 12)
        #expect(fallback["instructions"] as? String == "")
        #expect(fallback["input"] as? [[String: String]] == [])
        #expect(fallback["reasoning"] == nil)
    }

    @Test(arguments: ["json_schema", "json_object"])
    func structuredFormatMapsToText(format: String) {
        let schema: [String: Any] = ["name": "corrections", "strict": true, "schema": ["type": "object"]]
        var responseFormat: [String: Any] = ["type": format]
        if format == "json_schema" { responseFormat["json_schema"] = schema }
        let body = OpenAIResponsesText.requestBody([
            "response_format": responseFormat,
            "text": ["verbosity": "low"]
        ])
        let text = body["text"] as? [String: Any]
        let mapped = text?["format"] as? [String: Any]
        #expect(text?["verbosity"] as? String == "low")
        #expect(mapped?["type"] as? String == format)
        #expect(body["response_format"] == nil)
        if format == "json_schema" {
            #expect(mapped?["name"] as? String == "corrections")
            #expect(mapped?["strict"] as? Bool == true)
            #expect(mapped?["schema"] as? [String: String] == ["type": "object"])
            #expect(mapped?["json_schema"] == nil)
        }
    }

    @Test func bufferedTextRefusalAndUsageNormalizeInOutputOrder() throws {
        let data = Data(#"""
            {"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[
            {"type":"output_text","text":"Hello"},{"type":"refusal","refusal":" no"},{"type":"unknown"}]},
            {"type":"message","content":[{"type":"output_text","text":" world"}]}],"usage":{"input_tokens":12,"output_tokens":3}}
            """#.utf8)
        let normalized = try JSONSerialization.jsonObject(with: OpenAIResponsesText.chatCompletionResponse(from: data)) as? [String: Any]
        let choices = normalized?["choices"] as? [[String: Any]]
        #expect((choices?.first?["message"] as? [String: String])?["content"] == "Hello no world")
        #expect(choices?.first?["finish_reason"] as? String == "stop")
        #expect(normalized?["usage"] as? [String: Int] == ["prompt_tokens": 12, "completion_tokens": 3])
    }

    @Test func truncationPreservedEvenWithNoVisibleText() throws {
        let data = Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8)
        let normalized = try JSONSerialization.jsonObject(with: OpenAIResponsesText.chatCompletionResponse(from: data)) as? [String: Any]
        let choices = normalized?["choices"] as? [[String: Any]]
        #expect(choices?.first?["finish_reason"] as? String == "length")
        #expect((choices?.first?["message"] as? [String: String])?["content"] == "")
        #expect(normalized?["usage"] == nil)
    }

    @Test(arguments: ["content_filter", "unknown"])
    func incompleteOtherReasonsFail(reason: String) {
        let data = Data(#"{"status":"incomplete","incomplete_details":{"reason":"\#(reason)"}}"#.utf8)
        #expect(throws: OpenAIResponsesTextError.invalidResponse) {
            try OpenAIResponsesText.chatCompletionResponse(from: data)
        }
    }

    @Test(arguments: [#"{"status":"failed","error":{"message":"Failed"}}"#, #"{"error":{"message":"Failed"}}"#])
    func remoteErrorsFail(json: String) {
        #expect(throws: OpenAIResponsesTextError.remote("Failed")) {
            try OpenAIResponsesText.chatCompletionResponse(from: Data(json.utf8))
        }
    }

    @Test(arguments: ["[]", "{}", #"{"status":"in_progress"}"#, #"{"status":"failed"}"#, #"{"error":{}}"#])
    func invalidResponseFails(json: String) {
        #expect(throws: OpenAIResponsesTextError.invalidResponse) {
            try OpenAIResponsesText.chatCompletionResponse(from: Data(json.utf8))
        }
    }

    @Test(arguments: ["https://api.openai.com/v1", "https://API.OPENAI.COM:443/v1"])
    func officialOrigin(baseURL: String) {
        #expect(OpenAIResponsesText.isOfficial(providerID: "openAI", baseURL: baseURL))
        #expect(!OpenAIResponsesText.isOfficial(providerID: "custom", baseURL: baseURL))
    }

    @Test(arguments: ["http://api.openai.com/v1", "https://api.openai.com:8443/v1", "https://api.openai.com.example/v1", "invalid"])
    func otherOriginsStayCompatible(baseURL: String) {
        #expect(!OpenAIResponsesText.isOfficial(providerID: "openAI", baseURL: baseURL))
    }
}

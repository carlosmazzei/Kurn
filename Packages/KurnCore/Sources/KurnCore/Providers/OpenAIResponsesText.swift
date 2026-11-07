import Foundation

public enum OpenAIResponsesTextError: Error, Equatable, Sendable {
    case invalidResponse
    case remote(String)
}

/// Maps the existing text-generation contract to stateless OpenAI Responses.
public enum OpenAIResponsesText {
    public static func isOfficial(providerID: String, baseURL: String) -> Bool {
        let url = URLComponents(string: baseURL)
        return providerID == "openAI" && url?.scheme?.lowercased() == "https"
            && url?.host?.lowercased() == "api.openai.com" && (url?.port == nil || url?.port == 443)
    }

    public static func requestBody(_ chat: [String: Any]) -> [String: Any] {
        var body = chat
        for key in ["messages", "response_format", "max_tokens", "max_completion_tokens", "stream_options", "reasoning_effort"] {
            body.removeValue(forKey: key)
        }
        let messages = chat["messages"] as? [[String: Any]] ?? []
        body["instructions"] = messages.filter { $0["role"] as? String == "system" }
            .compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        body["input"] = messages.filter { $0["role"] as? String != "system" }
        body["store"] = false
        body["max_output_tokens"] = chat["max_completion_tokens"] ?? chat["max_tokens"]
        if let effort = chat["reasoning_effort"] { body["reasoning"] = ["effort": effort] }
        if let format = chat["response_format"] as? [String: Any] {
            var mapped = format
            if format["type"] as? String == "json_schema" {
                mapped = format["json_schema"] as? [String: Any] ?? [:]
                mapped["type"] = "json_schema"
            }
            var text = body["text"] as? [String: Any] ?? [:]
            text["format"] = mapped
            body["text"] = text
        }
        return body
    }

    /// Normalizes buffered output to the existing text/summary parsing contract.
    public static func chatCompletionResponse(from data: Data) throws -> Data {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIResponsesTextError.invalidResponse
        }
        if let error = response["error"] as? [String: Any] {
            throw OpenAIResponsesTextError.remote(error["message"] as? String ?? "Response failed")
        }
        let status = response["status"] as? String
        let details = response["incomplete_details"] as? [String: Any]
        let truncated = status == "incomplete" && details?["reason"] as? String == "max_output_tokens"
        if status == "failed" { throw OpenAIResponsesTextError.remote("Response failed") }
        if status == "incomplete", !truncated {
            throw OpenAIResponsesTextError.remote("Incomplete response: \(details?["reason"] as? String ?? "unknown")")
        }
        guard status == "completed" || truncated else { throw OpenAIResponsesTextError.invalidResponse }
        let output = response["output"] as? [[String: Any]] ?? []
        let text = output.filter { $0["type"] as? String == "message" }.flatMap { item in
            (item["content"] as? [[String: Any]] ?? []).compactMap { content -> String? in
                switch content["type"] as? String {
                case "output_text": return content["text"] as? String
                case "refusal": return content["refusal"] as? String
                default: return nil
                }
            }
        }.joined()
        var normalized: [String: Any] = ["choices": [["message": ["content": text], "finish_reason": truncated ? "length" : "stop"]]]
        if let usage = response["usage"] as? [String: Any] {
            normalized["usage"] = ["prompt_tokens": usage["input_tokens"] ?? 0, "completion_tokens": usage["output_tokens"] ?? 0]
        }
        return try JSONSerialization.data(withJSONObject: normalized)
    }
}

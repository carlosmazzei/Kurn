import Foundation

extension AgentWireFormat {
    public static let responsesMinimumOutputTokens = 16

    /// `visibleReasoning` also asks for the reasoning summary the chat shows while the model thinks.
    func responsesBody(_ request: AgentTurnRequest, model: String, reasoningEffort: String?,
                       visibleReasoning: Bool = false, promptCacheKey: String? = nil) -> JSONValue {
        var input: [JSONValue] = []
        for message in request.messages {
            switch message {
            case .content(let message): input += responsesContent(message, model: model)
            case .user(let text):
                input.append(.object(["role": .string("user"), "content": .string(text)]))
            case .assistant(let text, let calls, let metadata):
                input += (metadata?["openAIResponses"]["reasoning"].array ?? []).filter { $0["type"].string == "reasoning" }
                if !text.isEmpty {
                    input.append(.object(["role": .string("assistant"), "content": .string(text)]))
                }
                input += calls.map { call in
                    .object(["type": .string("function_call"), "call_id": .string(call.id),
                             "name": .string(call.name), "arguments": .string(call.rawArguments)])
                }
            case .tool(let result):
                input.append(.object(["type": .string("function_call_output"), "call_id": .string(result.invocation.callID), "output": .string(result.text)]))
            case .toolResult(let callID, _, let content, _):
                input.append(.object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(content)]))
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "instructions": .string(request.systemPrompt), "input": .array(input),
            // Responses requires at least 16, as in pi's OpenAI adapter (#6265).
            "stream": .bool(true), "store": .bool(false),
            "max_output_tokens": .number(Double(max(Self.responsesMinimumOutputTokens, request.maxOutputTokens))),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { spec in
                .object(["type": .string("function"), "name": .string(spec.name),
                         "description": .string(spec.description), "parameters": spec.inputSchema, "strict": .bool(false)])
            })
            if !request.allowsToolCalls { body["tool_choice"] = .string("none") }
        }
        // OpenAI routes requests with the same key to the same cache (its caching is automatic).
        if let promptCacheKey { body["prompt_cache_key"] = .string(promptCacheKey) }
        if let reasoningEffort {
            var reasoning: [String: JSONValue] = ["effort": .string(reasoningEffort)]
            if visibleReasoning { reasoning["summary"] = .string("auto") }
            body["reasoning"] = .object(reasoning)
        }
        return .object(body)
    }
}

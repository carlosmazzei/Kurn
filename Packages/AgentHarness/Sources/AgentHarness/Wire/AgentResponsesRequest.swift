import Foundation

extension AgentWireFormat {
    func responsesBody(_ request: AgentTurnRequest, model: String, reasoningEffort: String?) -> JSONValue {
        var input: [JSONValue] = []
        for message in request.messages {
            switch message {
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
            case .toolResult(let callID, _, let content, _):
                input.append(.object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(content)]))
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "instructions": .string(request.systemPrompt), "input": .array(input),
            "stream": .bool(true), "store": .bool(false), "max_output_tokens": .number(Double(request.maxOutputTokens)),
            "include": .array([.string("reasoning.encrypted_content")])
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { spec in
                .object(["type": .string("function"), "name": .string(spec.name),
                         "description": .string(spec.description), "parameters": spec.inputSchema, "strict": .bool(false)])
            })
        }
        if let reasoningEffort { body["reasoning"] = .object(["effort": .string(reasoningEffort)]) }
        return .object(body)
    }
}

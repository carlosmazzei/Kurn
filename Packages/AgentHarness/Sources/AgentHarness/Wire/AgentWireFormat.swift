import Foundation

public enum AgentWireFormat: Sendable, CaseIterable {
    case anthropic, openAI, openAIResponses, gemini

    /// Gemini streams through its URL route, not a `stream` body field.
    public func requestBody(_ request: AgentTurnRequest, model: String,
                            openAITokenField: String = "max_completion_tokens",
                            reasoningEffort: String? = nil) -> JSONValue {
        requestProjection(request, model: model, openAITokenField: openAITokenField, reasoningEffort: reasoningEffort).body
    }

    public func requestProjection(_ request: AgentTurnRequest, model: String,
                                  openAITokenField: String = "max_completion_tokens",
                                  reasoningEffort: String? = nil) -> AgentWireRequestProjection {
        var projection = AgentReplayProjection(format: self, model: model)
        let request = AgentTurnRequest(systemPrompt: request.systemPrompt, messages: projection.messages(request.messages),
            tools: request.tools, maxOutputTokens: request.maxOutputTokens, allowsToolCalls: request.allowsToolCalls)
        let body: JSONValue
        switch self {
        case .anthropic: body = anthropicBody(request, model: model)
        case .openAI:
            body = openAIBody(request, model: model, tokenField: openAITokenField, reasoningEffort: reasoningEffort)
        case .gemini: body = geminiBody(request, model: model)
        case .openAIResponses: body = responsesBody(request, model: model, reasoningEffort: reasoningEffort)
        }
        return AgentWireRequestProjection(body: body, adjustment: projection.adjustment)
    }

    private func openAIBody(_ request: AgentTurnRequest, model: String, tokenField: String,
                            reasoningEffort: String?) -> JSONValue {
        let messages: [JSONValue] = [.object(["role": .string("system"), "content": .string(request.systemPrompt)])]
            + request.messages.map { message in
                switch message {
                case .content(let message): return openAIContent(message, model: model)
                case .user(let text): return .object(["role": .string("user"), "content": .string(text)])
                case .assistant(let text, let calls, _):
                    var value: [String: JSONValue] = ["role": .string("assistant"), "content": .string(text)]
                    if !calls.isEmpty {
                        value["tool_calls"] = .array(calls.map { call in
                            .object(["id": .string(call.id), "type": .string("function"),
                                     "function": .object(["name": .string(call.name), "arguments": .string(call.rawArguments)])])
                        })
                    }
                    return .object(value)
                case .toolResult(let callID, _, let content, _):
                    return .object(["role": .string("tool"), "tool_call_id": .string(callID), "content": .string(content)])
                }
            }
        var body: [String: JSONValue] = [
            "model": .string(model), tokenField: .number(Double(request.maxOutputTokens)), "messages": .array(messages),
            "stream": .bool(true), "stream_options": .object(["include_usage": .bool(true)])
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { spec in
                .object(["type": .string("function"), "function": .object([
                    "name": .string(spec.name), "description": .string(spec.description), "parameters": spec.inputSchema])])
            })
            if !request.allowsToolCalls { body["tool_choice"] = .string("none") }
        }
        if let reasoningEffort { body["reasoning_effort"] = .string(reasoningEffort) }
        return .object(body)
    }

    private func anthropicBody(_ request: AgentTurnRequest, model: String) -> JSONValue {
        var messages: [JSONValue] = []
        for message in request.messages {
            switch message {
            case .content(let message):
                append(role: message.role.rawValue, parts: contentParts(message, model: model), to: &messages, field: "content")
            case .user(let text):
                append(role: "user", parts: [.object(["type": .string("text"), "text": .string(text)])],
                       to: &messages, field: "content")
            case .assistant(let text, let calls, _):
                var blocks: [JSONValue] = text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
                blocks += calls.map { call in
                    .object(["type": .string("tool_use"), "id": .string(call.id),
                             "name": .string(call.name), "input": call.arguments])
                }
                append(role: "assistant", parts: blocks, to: &messages, field: "content")
            case .toolResult(let callID, _, let content, let isError):
                append(role: "user", parts: [.object(["type": .string("tool_result"), "tool_use_id": .string(callID),
                    "content": .string(content), "is_error": .bool(isError)])], to: &messages, field: "content")
            }
        }
        var body: [String: JSONValue] = ["model": .string(model), "system": .string(request.systemPrompt),
            "messages": .array(messages), "max_tokens": .number(Double(request.maxOutputTokens)), "stream": .bool(true)]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema])
            })
            if !request.allowsToolCalls { body["tool_choice"] = .object(["type": .string("none")]) }
        }
        return .object(body)
    }

    private func geminiBody(_ request: AgentTurnRequest, model: String) -> JSONValue {
        var contents: [JSONValue] = []
        var callsByID: [String: AgentToolCall] = [:]
        for message in request.messages {
            switch message {
            case .content(let message):
                for call in message.toolCalls { callsByID[call.id] = call }
                append(role: message.role == .user ? "user" : "model", parts: contentParts(message, model: model),
                       to: &contents, field: "parts")
            case .user(let text):
                append(role: "user", parts: [.object(["text": .string(text)])], to: &contents, field: "parts")
            case .assistant(let text, let calls, _):
                var parts: [JSONValue] = text.isEmpty ? [] : [.object(["text": .string(text)])]
                for call in calls {
                    callsByID[call.id] = call
                    var function: [String: JSONValue] = ["name": .string(call.name), "args": call.arguments]
                    if let wireID = call.providerMetadata?["geminiID"].string { function["id"] = .string(wireID) }
                    var part: [String: JSONValue] = ["functionCall": .object(function)]
                    if let signature = call.providerMetadata?["thoughtSignature"].string {
                        part["thoughtSignature"] = .string(signature)
                    }
                    parts.append(.object(part))
                }
                append(role: "model", parts: parts, to: &contents, field: "parts")
            case .toolResult(let callID, let name, let content, let isError):
                let call = callsByID[callID]
                var response: [String: JSONValue] = ["name": .string(call?.name ?? name),
                    "response": .object([isError ? "error" : "result": .string(content)])]
                if let wireID = call?.providerMetadata?["geminiID"].string { response["id"] = .string(wireID) }
                append(role: "user", parts: [.object(["functionResponse": .object(response)])], to: &contents, field: "parts")
            }
        }
        var body: [String: JSONValue] = [
            "systemInstruction": .object(["parts": .array([.object(["text": .string(request.systemPrompt)])])]),
            "contents": .array(contents),
            "generationConfig": .object(["maxOutputTokens": .number(Double(request.maxOutputTokens))])
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array([.object(["functionDeclarations": .array(request.tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema])
            })])])
            if !request.allowsToolCalls {
                body["toolConfig"] = .object(["functionCallingConfig": .object(["mode": .string("NONE")])])
            }
        }
        return .object(body)
    }

    private func append(role: String, parts: [JSONValue], to messages: inout [JSONValue], field: String) {
        if let last = messages.last, last["role"].string == role {
            messages[messages.count - 1] = .object(["role": .string(role), field: .array(last[field].array + parts)])
        } else {
            messages.append(.object(["role": .string(role), field: .array(parts)]))
        }
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue {
        guard case .object(let values) = self else { return .null }
        return values[key] ?? .null
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var array: [JSONValue] {
        guard case .array(let values) = self else { return [] }
        return values
    }

    var int: Int? {
        guard case .number(let value) = self, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }
}

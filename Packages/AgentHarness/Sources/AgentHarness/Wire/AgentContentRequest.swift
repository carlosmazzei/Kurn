import Foundation

extension AgentWireFormat {
    static let omittedThinking = "[Thinking omitted: replay is unsupported or belongs to a different model]"
    static let omittedImage = "[Image omitted: unsupported by this message role or API]"

    func contentParts(_ message: AgentContentMessage, model: String) -> [JSONValue] {
        let compatible = AgentReplayProjection(format: self, model: model).compatible(message)
        return message.blocks.compactMap { block in
            switch block.content {
            case .text(let text, let signature):
                if self == .gemini {
                    var part: [String: JSONValue] = ["text": .string(text)]
                    if compatible, let signature { part["thoughtSignature"] = .string(signature) }
                    return .object(part)
                }
                return .object(["type": .string("text"), "text": .string(text)])
            case .thinking(let text, let signature, let redacted, _):
                if self == .anthropic, compatible, let signature {
                    return redacted ? .object(["type": .string("redacted_thinking"), "data": .string(signature)])
                        : .object(["type": .string("thinking"), "thinking": .string(text ?? ""), "signature": .string(signature)])
                }
                if self == .gemini, compatible, let signature {
                    return .object(["text": .string(text ?? ""), "thought": .bool(true), "thoughtSignature": .string(signature)])
                }
                return self == .gemini ? .object(["text": .string(Self.omittedThinking)])
                    : .object(["type": .string("text"), "text": .string(Self.omittedThinking)])
            case .toolCall(let call, _):
                if self == .anthropic {
                    return .object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name), "input": call.arguments])
                }
                if self == .gemini {
                    var function: [String: JSONValue] = ["name": .string(call.name), "args": call.arguments]
                    if let id = call.providerMetadata?["geminiID"].string { function["id"] = .string(id) }
                    var part: [String: JSONValue] = ["functionCall": .object(function)]
                    if let signature = call.providerMetadata?["thoughtSignature"].string { part["thoughtSignature"] = .string(signature) }
                    return .object(part)
                }
                return nil
            case .image(let mime, let base64):
                if self == .gemini { return .object(["inlineData": .object(["mimeType": .string(mime), "data": .string(base64)])]) }
                guard message.role == .user else { return .object(["type": .string("text"), "text": .string(Self.omittedImage)]) }
                if self == .anthropic {
                    return .object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string(mime), "data": .string(base64)])])
                }
                return .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:\(mime);base64,\(base64)")])])
            }
        }
    }

    func openAIContent(_ message: AgentContentMessage, model: String) -> JSONValue {
        var value: [String: JSONValue] = ["role": .string(message.role.rawValue), "content": .array(contentParts(message, model: model))]
        if !message.toolCalls.isEmpty {
            value["tool_calls"] = .array(message.toolCalls.map { call in
                .object(["id": .string(call.id), "type": .string("function"),
                    "function": .object(["name": .string(call.name), "arguments": .string(call.rawArguments)])])
            })
        }
        return .object(value)
    }

    func responsesContent(_ message: AgentContentMessage, model: String) -> [JSONValue] {
        let compatible = AgentReplayProjection(format: self, model: model).compatible(message)
        return message.blocks.map { block in
            switch block.content {
            case .toolCall(let call, _):
                return .object(["type": .string("function_call"), "call_id": .string(call.id),
                                "name": .string(call.name), "arguments": .string(call.rawArguments)])
            case .thinking(_, _, _, let metadata):
                if compatible, let metadata, metadata["type"].string == "reasoning" { return metadata }
                return .object(["role": .string(message.role.rawValue), "content": .string(Self.omittedThinking)])
            case .text(let text, _): return .object(["role": .string(message.role.rawValue), "content": .string(text)])
            case .image(let mime, let data):
                if message.role == .user {
                    return .object(["role": .string("user"), "content": .array([.object([
                        "type": .string("input_image"), "image_url": .string("data:\(mime);base64,\(data)")])])])
                }
                return .object(["role": .string("assistant"), "content": .string(Self.omittedImage)])
            }
        }
    }
}

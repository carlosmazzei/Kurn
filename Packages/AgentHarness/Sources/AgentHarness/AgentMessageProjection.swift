import Foundation

extension AgentMessage {
    /// A disposable legacy projection for old codecs and summary text, never a canonical writer.
    public var legacyProjection: AgentMessage {
        if case .tool(let result) = self {
            return .toolResult(callID: result.invocation.callID, toolName: result.invocation.toolName, content: result.text, isError: result.isError)
        }
        guard case .content(let message) = self else { return self }
        switch message.role {
        case .user: return .user(message.text)
        case .assistant:
            let calls = message.toolCalls.map { AgentToolCall(id: $0.id, name: $0.name, arguments: $0.arguments,
                rawArguments: $0.rawArguments, providerMetadata: $0.providerMetadata, namespace: $0.namespace) }
            var metadata: [String: JSONValue] = [:]
            if case .object(let raw) = message.providerMetadata { metadata = raw; metadata.removeValue(forKey: "rawStopReason") }
            if message.identity?.api == "openAIResponses" {
                let reasoning = message.blocks.compactMap { block -> JSONValue? in
                    if case .thinking(_, _, _, let data) = block.content { return data }; return nil
                }
                if !reasoning.isEmpty { metadata["openAIResponses"] = .object(["reasoning": .array(reasoning)]) }
            }
            return .assistant(text: message.text, toolCalls: calls, providerMetadata: metadata.isEmpty ? nil : .object(metadata))
        }
    }
}

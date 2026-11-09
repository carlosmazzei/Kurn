import Foundation

/// Creates live messages once. Historical input remains untouched, including unknown timestamps.
enum AgentMessageFactory {
    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    static func user(_ text: String) throws -> AgentMessage {
        .content(try AgentContentMessage(id: UUID().uuidString, timestampMilliseconds: now, role: .user,
            blocks: [AgentContentBlock(id: "text", content: .text(text))]))
    }

    static func assistant(_ message: AgentContentMessage, request: AgentRequestIdentity,
                          descriptor: AgentModelDescriptor?) throws -> AgentContentMessage {
        guard message.role == .assistant, message.stopReason != nil else { throw AgentWireError.invalidResponse }
        let previous = message.identity
        let identity = AgentResponseIdentity(api: previous?.api ?? descriptor?.api, model: previous?.model ?? descriptor?.model,
            responseID: previous?.responseID, requestID: request.id)
        let blocks = message.blocks.map { block -> AgentContentBlock in
            guard case .toolCall(let call, let complete) = block.content else { return block }
            let invocationID = previous?.requestID == request.id ? (call.invocationID ?? UUID().uuidString) : UUID().uuidString
            let normalized = AgentToolCall(id: call.id, name: call.name, arguments: (try? JSONValue.parse(call.rawArguments)) ?? .null,
                rawArguments: call.rawArguments, providerMetadata: call.providerMetadata, namespace: call.namespace, invocationID: invocationID)
            return AgentContentBlock(id: block.id, content: .toolCall(normalized, complete: complete))
        }
        return try AgentContentMessage(id: previous?.requestID == request.id ? message.id : UUID().uuidString, timestampMilliseconds: message.timestampMilliseconds, role: .assistant,
            blocks: blocks, identity: identity, stopReason: message.stopReason, usage: message.usage, providerMetadata: message.providerMetadata)
    }

    static func failure(_ failure: AgentStreamFailure, blocks: [AgentContentBlock], request: AgentRequestIdentity,
                        descriptor: AgentModelDescriptor?) throws -> AgentContentMessage {
        var seen = Set<String>()
        let blocks = blocks.map { block -> AgentContentBlock in
            guard case .toolCall(let call, let complete) = block.content else { return block }
            var metadata: [String: JSONValue] = [:]
            if case .object(let original) = call.providerMetadata { metadata = original }
            let id: String
            if AgentContentMessage.validID(call.id), seen.insert(call.id).inserted { id = call.id }
            else { id = UUID().uuidString; metadata["originalCallID"] = .string(call.id) }
            let name: String
            if call.name.utf8.count <= 256 { name = call.name }
            else { name = "unknown_tool"; metadata["originalToolName"] = .string(call.name) }
            let namespace: String?
            if let raw = call.namespace, !AgentContentMessage.validID(raw) {
                namespace = nil; metadata["originalNamespace"] = .string(raw)
            } else { namespace = call.namespace }
            let safe = AgentToolCall(id: id, name: name, arguments: (try? JSONValue.parse(call.rawArguments)) ?? .null,
                rawArguments: call.rawArguments, providerMetadata: metadata.isEmpty ? nil : .object(metadata),
                namespace: namespace, invocationID: UUID().uuidString)
            return AgentContentBlock(id: block.id, content: .toolCall(safe, complete: complete))
        }
        let reason: AgentModelStopReason = failure == .cancelled ? .aborted : failure == .deferred ? .deferred : .error
        return try AgentContentMessage(id: UUID().uuidString, timestampMilliseconds: now, role: .assistant, blocks: blocks,
            identity: AgentResponseIdentity(api: descriptor?.api, model: descriptor?.model, requestID: request.id), stopReason: reason,
            providerMetadata: .object(["failure": .string(failure.rawValue)]))
    }

    static func invocation(_ call: AgentToolCall, requestID: String) throws -> AgentToolInvocation {
        try AgentToolInvocation(id: call.invocationID ?? UUID().uuidString, requestID: requestID,
                               callID: call.id, toolName: call.name, namespace: call.namespace)
    }

    static func result(_ invocation: AgentToolInvocation, output: AgentToolOutput, isError: Bool,
                       syntheticReason: AgentToolBlockReason? = nil) throws -> AgentMessage {
        let details: JSONValue? = output.metrics.isEmpty ? nil : .object(Dictionary(uniqueKeysWithValues:
            output.metrics.map { ($0.key.rawValue, JSONValue.number(Double($0.value))) }))
        return .tool(try AgentToolResultMessage(id: UUID().uuidString, timestampMilliseconds: now, invocation: invocation,
            blocks: [AgentContentBlock(id: "text", content: .text(output.content))], isError: isError, syntheticReason: syntheticReason, details: details))
    }
}

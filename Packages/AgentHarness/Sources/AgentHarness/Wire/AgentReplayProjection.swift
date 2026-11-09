import Foundation

/// Provider copies may normalize IDs, omit unsupported blocks and remove incompatible signatures.
/// The original canonical messages are never modified by request preparation.
struct AgentReplayProjection {
    let format: AgentWireFormat
    let model: String
    var adjustment = AgentReplayAdjustment()
    var invocations: [String: String] = [:]
    var skippedInvocations = Set<String>()
    var ids: [String: String] = [:]
    var used = Set<String>()

    mutating func messages(_ messages: [AgentMessage]) -> [AgentMessage] {
        messages.compactMap { message in
            switch message {
            case .content(let value):
                if value.stopReason == .error || value.stopReason == .aborted || value.stopReason == .deferred {
                    skippedInvocations.formUnion(value.toolCalls.compactMap(\.invocationID))
                    adjustment.omittedMessages += 1
                    return nil
                }
                recordOmissions(value)
                let copy = value.projectingToolCalls { original, complete in
                    let id = wireID(original.id, namespace: value.id)
                    ids[original.id] = id
                    if let invocation = original.invocationID { invocations[invocation] = id }
                    if original.namespace != nil { adjustment.omittedNamespaces += 1 }
                    if id != original.id { adjustment.normalizedCallIDs += 1 }
                    if !complete || !original.hasValidArguments { adjustment.sanitizedArguments += 1 }
                    let raw = complete && original.hasValidArguments ? original.rawArguments : "{}"
                    return AgentToolCall(id: id, name: original.name, arguments: (try? JSONValue.parse(raw)) ?? .object([:]),
                        rawArguments: raw, providerMetadata: compatible(value) ? original.providerMetadata : nil,
                        namespace: original.namespace, invocationID: original.invocationID)
                }
                return .content(copy)
            case .tool(let result):
                if skippedInvocations.contains(result.invocation.id) {
                    adjustment.omittedMessages += 1
                    return nil
                }
                let callID = invocations[result.invocation.id] ?? ids[result.invocation.callID] ?? result.invocation.callID
                let text = result.blocks.map { block -> String in
                    switch block.content {
                    case .text(let text, _): return text
                    case .image: adjustment.omittedImages += 1; return AgentWireFormat.omittedImage
                    default: return "" // The checked result codec forbids thinking/tool blocks.
                    }
                }.joined()
                return .toolResult(callID: callID, toolName: result.invocation.toolName, content: text, isError: result.isError)
            case .assistant(_, let calls, _):
                for call in calls { ids[call.id] = call.id; used.insert(call.id) }
                return message
            case .toolResult(let id, let name, let content, let error):
                return .toolResult(callID: ids[id] ?? id, toolName: name, content: content, isError: error)
            case .user: return message
            }
        }
    }

    func compatible(_ message: AgentContentMessage) -> Bool {
        guard let identity = message.identity else { return false }
        return identity.api == api && (identity.model == nil || identity.model == model)
    }

    private var api: String {
        switch format { case .anthropic: "anthropic"; case .openAI: "openAI"; case .openAIResponses: "openAIResponses"; case .gemini: "gemini" }
    }

    private mutating func wireID(_ original: String, namespace: String) -> String {
        let allowed = original.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        if !original.isEmpty, original.utf8.count <= 64, allowed, used.insert(original).inserted { return original }
        // Stable FNV-1a avoids process-randomized Swift Hasher and keeps IDs within every adapter's alphabet.
        let hash = (namespace + "\0" + original).utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let base = "call_" + String(hash, radix: 16)
        var id = base
        var suffix = 1
        while !used.insert(id).inserted { id = base + "_\(suffix)"; suffix += 1 }
        return id
    }
}

import Foundation

extension AgentWireState {
    mutating func gemini(_ value: JSONValue) throws {
        model = value["modelVersion"].string ?? model
        responseID = value["responseId"].string ?? responseID
        geminiUsage(value["usageMetadata"])
        guard let candidate = value["candidates"].array.first(where: { ($0["index"].int ?? 0) == 0 }) else { return }
        for part in candidate["content"]["parts"].array { try geminiPart(part) }
        guard let reason = candidate["finishReason"].string else { return }
        rawStopReason = reason
        let hasCalls = reducer.blocks.contains { if case .toolCall = $0.content { return true }; return false }
        stopReason = reason == "MAX_TOKENS" ? .maxTokens : reason == "STOP" ? (hasCalls ? .toolUse : .endTurn) : .other(reason)
        if stopReason != .maxTokens { try finishCalls() }
        terminal = true
    }

    mutating func geminiUsage(_ usage: JSONValue) {
        if let input = usage["promptTokenCount"].int { inputTokens = input }
        if let reasoning = usage["thoughtsTokenCount"].int { reasoningTokens = reasoning }
        if let cached = usage["cachedContentTokenCount"].int { cacheReadTokens = cached }
        if let output = usage["candidatesTokenCount"].int { geminiOutputTokens = output }
        if let output = geminiOutputTokens { outputTokens = output + (reasoningTokens ?? 0) }
    }

    mutating func geminiPart(_ part: JSONValue) throws {
        let function = part["functionCall"]
        if let name = function["name"].string {
            let wireID = function["id"].string
            let index = reducer.blocks.filter { if case .toolCall = $0.content { return true }; return false }.count
            let slot = allocated(wireID.map { "call:\($0)" } ?? "call:\(index)")
            var metadata: [String: JSONValue] = [:]
            if let wireID { metadata["geminiID"] = .string(wireID) }
            if let signature = part["thoughtSignature"].string { metadata["thoughtSignature"] = .string(signature) }
            let args = function["args"] == .null ? JSONValue.object([:]) : function["args"]
            let call = AgentToolCall(id: wireID ?? "\(callIDPrefix)-\(index)", name: name, arguments: args,
                                    rawArguments: try args.encodedString(), providerMetadata: metadata.isEmpty ? nil : .object(metadata), namespace: function["namespace"].string)
            if function["partialArgs"] != .null || function["willContinue"] == .bool(true) { throw AgentWireError.incompleteToolCall }
            if block(slot) == nil { try start(slot, .toolCall(call, complete: false)) }
            else { try update(slot, .toolCall(call, complete: false)) }
            lastGeminiKind = nil
            return
        }
        if function != .null { throw AgentWireError.incompleteToolCall }
        let thinking = part["thought"] == .bool(true)
        if part["text"].string != nil || thinking || part["thoughtSignature"].string != nil {
            let kind = thinking ? "thinking" : "text"
            let slot: Int
            if lastGeminiKind == kind, let previous = lastGeminiSlot { slot = previous }
            else {
                slot = allocated("part:\(nextSlot)")
                lastGeminiKind = kind
                lastGeminiSlot = slot
            }
            try text(part["text"].string, slot: slot, thinking: thinking)
            if let signature = part["thoughtSignature"].string {
                if thinking {
                    if block(slot) == nil { try start(slot, .thinking(text: "", signature: nil, redacted: false)) }
                    try delta(slot, .signature(signature))
                } else {
                    let current: String
                    if case .text(let text, _) = block(slot)?.content { current = text } else { current = "" }
                    if block(slot) == nil { try start(slot, .text(current, signature: signature)) }
                    else { try update(slot, .text(current, signature: signature)) }
                }
            }
        } else if let mime = part["inlineData"]["mimeType"].string, let data = part["inlineData"]["data"].string {
            let slot = allocated("image:\(nextSlot)")
            try start(slot, .image(mimeType: mime, base64: data))
            lastGeminiKind = nil
        } else { throw AgentWireError.invalidResponse }
    }
}

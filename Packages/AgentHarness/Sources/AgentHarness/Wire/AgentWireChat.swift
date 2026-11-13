import Foundation

extension AgentWireState {
    mutating func openAIUsage(_ usage: JSONValue) {
        if let input = usage["prompt_tokens"].int { inputTokens = input }
        if let output = usage["completion_tokens"].int { outputTokens = output }
        if let reasoning = usage["completion_tokens_details"]["reasoning_tokens"].int { reasoningTokens = reasoning }
        if let cached = usage["prompt_tokens_details"]["cached_tokens"].int { cacheReadTokens = cached }
    }

    mutating func openAI(_ value: JSONValue) throws {
        openAIUsage(value["usage"])
        model = value["model"].string ?? model
        responseID = value["id"].string ?? responseID
        guard let choice = value["choices"].array.first(where: { ($0["index"].int ?? 0) == 0 }) else { return }
        let fragment = choice["delta"]
        if let thinking = fragment["reasoning_content"].string ?? fragment["reasoning"].string {
            let slot = chatTextSlot(thinking: true)
            try text(thinking, slot: slot, thinking: true)
        }
        if let content = fragment["content"].string {
            let slot = chatTextSlot(thinking: false)
            try text(content, slot: slot)
        }
        for item in fragment["tool_calls"].array {
            guard let index = item["index"].int, index < 4_096 else { throw AgentWireError.invalidResponse }
            let key = "call\(index)"
            let slot: Int
            if let existing = slots[key] { slot = existing }
            else {
                let base: Int
                if let existing = chatCallBase { base = existing }
                else { base = nextSlot; chatCallBase = base; nextSlot += 4_096 }
                slot = base + index
                slots[key] = slot
            }
            if block(slot) == nil {
                lastChatKind = nil
                try start(slot, .toolCall(AgentToolCall(id: "", name: "", arguments: .null, rawArguments: ""), complete: false))
            }
            try delta(slot, .toolCall(id: item["id"].string, name: item["function"]["name"].string,
                                     arguments: item["function"]["arguments"].string))
            if let namespace = item["namespace"].string ?? item["function"]["namespace"].string,
               case .toolCall(let call, let complete) = block(slot)?.content {
                try update(slot, .toolCall(AgentToolCall(id: call.id, name: call.name, arguments: call.arguments,
                    rawArguments: call.rawArguments, providerMetadata: call.providerMetadata, namespace: namespace,
                    invocationID: call.invocationID), complete: complete))
            }
        }
        guard let reason = choice["finish_reason"].string else { return }
        rawStopReason = reason
        stopReason = reason == "length" ? .maxTokens : reason == "stop" ? .endTurn
            : ["tool_calls", "function_call"].contains(reason) ? .toolUse : .other(reason)
        if stopReason != .maxTokens { try finishCalls() }
        terminal = true
    }

    private mutating func chatTextSlot(thinking: Bool) -> Int {
        let kind = thinking ? "thinking" : "text"
        if lastChatKind == kind, let slot = lastChatSlot { return slot }
        let slot = allocated("chat-part:\(nextSlot)")
        lastChatKind = kind
        lastChatSlot = slot
        return slot
    }

}

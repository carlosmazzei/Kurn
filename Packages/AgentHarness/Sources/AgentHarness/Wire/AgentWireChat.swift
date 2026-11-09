import Foundation

extension AgentWireState {
    mutating func openAIUsage(_ usage: JSONValue) {
        if let input = usage["prompt_tokens"].int { inputTokens = input }
        if let output = usage["completion_tokens"].int { outputTokens = output }
        if let reasoning = usage["completion_tokens_details"]["reasoning_tokens"].int { reasoningTokens = reasoning }
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

    mutating func anthropic(_ value: JSONValue) throws {
        if anthropicStopReceived, !["message_stop", "message_delta", "ping"].contains(value["type"].string ?? "") {
            throw AgentWireError.invalidResponse
        }
        switch value["type"].string {
        case "error": throw AgentWireError.remote(value["error"]["message"].string ?? "Stream error")
        case "message_start":
            let message = value["message"]
            model = message["model"].string
            responseID = message["id"].string
            inputTokens = message["usage"]["input_tokens"].int
            outputTokens = message["usage"]["output_tokens"].int
        case "content_block_start":
            guard let index = value["index"].int, index < 4_096 else { throw AgentWireError.invalidResponse }
            let content = value["content_block"]
            switch content["type"].string {
            case "text": try text(content["text"].string ?? "", slot: index)
            case "thinking":
                try start(index, .thinking(text: content["thinking"].string ?? "", signature: content["signature"].string, redacted: false))
            case "redacted_thinking":
                try start(index, .thinking(text: nil, signature: content["data"].string, redacted: true))
            case "tool_use":
                let input = content["input"] == .null ? JSONValue.object([:]) : content["input"]
                let raw = input == .object([:]) ? "" : try input.encodedString()
                try start(index, .toolCall(AgentToolCall(id: content["id"].string ?? "", name: content["name"].string ?? "",
                    arguments: input, rawArguments: raw), complete: false))
            default: throw AgentWireError.invalidResponse
            }
        case "content_block_delta":
            let index = value["index"].int ?? 0
            guard index < 4_096 else { throw AgentWireError.invalidResponse }
            let part = value["delta"]
            switch part["type"].string {
            case "text_delta": try text(part["text"].string, slot: index)
            case "thinking_delta": try text(part["thinking"].string, slot: index, thinking: true)
            case "signature_delta": try delta(index, .signature(part["signature"].string ?? ""))
            case "input_json_delta": try delta(index, .toolCall(id: nil, name: nil, arguments: part["partial_json"].string))
            default: throw AgentWireError.invalidResponse
            }
        case "content_block_stop":
            guard let index = value["index"].int, let current = block(index) else { return }
            if case .toolCall(let call, _) = current.content {
                let raw = call.rawArguments.isEmpty ? "{}" : call.rawArguments
                try update(index, .toolCall(AgentToolCall(id: call.id, name: call.name,
                    arguments: (try? JSONValue.parse(raw)) ?? .null, rawArguments: raw), complete: true))
            }
        case "message_delta":
            if let input = value["usage"]["input_tokens"].int { inputTokens = input }
            if let output = value["usage"]["output_tokens"].int { outputTokens = output }
            guard let reason = value["delta"]["stop_reason"].string else { return }
            rawStopReason = reason
            stopReason = reason == "max_tokens" ? .maxTokens : reason == "tool_use" ? .toolUse
                : ["end_turn", "stop_sequence"].contains(reason) ? .endTurn
                : reason == "pause_turn" ? .deferred : .other(reason)
            anthropicStopReceived = true
        case "message_stop":
            if !anthropicStopReceived {
                stopReason = reducer.blocks.contains { if case .toolCall = $0.content { return true }; return false } ? .toolUse : .endTurn
            }
            terminal = true
        default: break
        }
    }
}

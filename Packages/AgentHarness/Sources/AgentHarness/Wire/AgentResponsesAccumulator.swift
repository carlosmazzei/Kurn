import Foundation

extension AgentWireState {
    mutating func responses(_ value: JSONValue) throws {
        let type = value["type"].string
        switch type {
        case "response.created", "response.in_progress":
            responseID = value["response"]["id"].string ?? responseID
            model = value["response"]["model"].string ?? model
        case "response.output_text.delta", "response.refusal.delta":
            let slot = try responseSlot(value)
            try text(value["delta"].string, slot: slot)
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            let slot = try responseSlot(value)
            try text(value["delta"].string, slot: slot, thinking: true)
        case "response.output_item.added", "response.output_item.done":
            guard let index = value["output_index"].int, index < 4_096 else { throw AgentWireError.invalidResponse }
            try responseItem(value["item"], index: index, complete: type == "response.output_item.done")
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            let slot: Int
            if let index = value["output_index"].int, index < 4_096 { slot = index * 4_096 }
            else if let id = value["item_id"].string, let found = responsesCalls[id] { slot = found }
            else { throw AgentWireError.incompleteToolCall }
            guard case .toolCall(let call, _) = block(slot)?.content else { throw AgentWireError.incompleteToolCall }
            if type == "response.function_call_arguments.delta" {
                try delta(slot, .toolCall(id: nil, name: nil, arguments: value["delta"].string))
            } else {
                let raw = value["arguments"].string ?? call.rawArguments
                let final = AgentToolCall(id: call.id, name: call.name, arguments: (try? JSONValue.parse(raw)) ?? .null,
                                          rawArguments: raw, providerMetadata: call.providerMetadata, namespace: call.namespace, invocationID: call.invocationID)
                try update(slot, .toolCall(final, complete: value["arguments"].string != nil))
            }
        case "response.completed", "response.incomplete": try finishResponses(value)
        case "response.failed":
            throw value["response"]["error"]["message"].string.map(AgentWireError.remote) ?? .invalidResponse
        case "error": throw value["message"].string.map(AgentWireError.remote) ?? .invalidResponse
        default: break
        }
    }

    mutating func responseSlot(_ value: JSONValue) throws -> Int {
        let index = value["output_index"].int ?? 0
        let content = value["content_index"].int ?? value["summary_index"].int ?? 0
        guard index < 4_096, content < 4_096 else { throw AgentWireError.invalidResponse }
        let slot = index * 4_096 + content
        registerResponseBlock(slot: slot, itemID: value["item_id"].string ?? responsesItemIDs[index], offset: content)
        return slot
    }

    private mutating func registerResponseBlock(slot: Int, itemID: String?, offset: Int) {
        guard let itemID else { return }
        let key = itemID + ":\(offset)"
        if let known = responsesKnownIDs[key] { responsesSlotIDs[slot] = known; return }
        let existing = block(slot)?.id
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let id = existing ?? "item-" + String(hash, radix: 16)
        responsesSlotIDs[slot] = id
        responsesKnownIDs[key] = id
    }

    mutating func responseItem(_ item: JSONValue, index: Int, complete: Bool) throws {
        let slot = index * 4_096
        let itemID = item["id"].string
        if let itemID { responsesItemIDs[index] = itemID }
        registerResponseBlock(slot: slot, itemID: itemID, offset: 0)
        switch item["type"].string {
        case "function_call":
            if let itemID = item["id"].string { responsesCalls[itemID] = slot }
            let previous: AgentToolCall?
            if case .toolCall(let call, _) = block(slot)?.content { previous = call } else { previous = nil }
            let raw = item["arguments"].string ?? previous?.rawArguments ?? ""
            let call = AgentToolCall(id: item["call_id"].string ?? previous?.id ?? "",
                name: item["name"].string ?? previous?.name ?? "", arguments: (try? JSONValue.parse(raw)) ?? .null, rawArguments: raw, namespace: item["namespace"].string ?? previous?.namespace)
            let content = AgentContentBlock.Content.toolCall(call,
                complete: complete && !["in_progress", "incomplete"].contains(item["status"].string ?? ""))
            if block(slot) == nil { try start(slot, content) } else { try update(slot, content) }
        case "reasoning":
            responsesReasoning[index] = item
            let summary = item["summary"].array.compactMap { $0["text"].string }.joined()
            let content = AgentContentBlock.Content.thinking(text: summary.isEmpty ? nil : summary,
                signature: item["encrypted_content"].string, redacted: item["encrypted_content"].string != nil && summary.isEmpty, metadata: item)
            if block(slot) == nil { try start(slot, content) } else { try update(slot, content) }
        case "message":
            for (offset, part) in item["content"].array.enumerated() {
                guard offset < 4_096 else { throw AgentWireError.bufferLimit }
                let position = slot + offset
                registerResponseBlock(slot: position, itemID: itemID, offset: offset)
                let kind = part["type"].string
                guard kind == "output_text" || kind == "refusal" else { throw AgentWireError.invalidResponse }
                let full = part[kind == "refusal" ? "refusal" : "text"].string ?? ""
                let streamed: String
                if case .text(let current, _) = block(position)?.content { streamed = current } else { streamed = "" }
                if full.hasPrefix(streamed) {
                    try text(String(full.dropFirst(streamed.count)), slot: position)
                } else if block(position) != nil { try update(position, .text(full)) }
                else if !full.isEmpty { try start(position, .text(full)) }
            }
        default: throw AgentWireError.invalidResponse
        }
    }

    mutating func finishResponses(_ value: JSONValue) throws {
        let response = value["response"]
        model = response["model"].string ?? model
        responseID = response["id"].string ?? responseID
        let limited = value["type"].string == "response.incomplete"
        if limited {
            guard response["incomplete_details"]["reason"].string == "max_output_tokens" else { throw AgentWireError.invalidResponse }
        }
        if case .array(let output) = response["output"] {
            guard output.count <= 4_096 else { throw AgentWireError.bufferLimit }
            let previous = reducer.blocks
            let priorEvents = events
            // Build the declared final snapshot independently: stale or differently typed blocks
            // cannot constrain an authoritative correction or reorder.
            reducer = AgentMessageReducer()
            responsesReasoning = [:]
            responsesSlotIDs = [:]
            responsesItemIDs = [:]
            events = []
            for (index, item) in output.enumerated() { try responseItem(item, index: index, complete: !limited) }
            events = priorEvents
            for block in reducer.blocks {
                guard case .text(let full, _) = block.content else { continue }
                let streamed: String
                if case .text(let text, _) = previous.first(where: { $0.id == block.id })?.content { streamed = text }
                else { streamed = "" }
                if full.hasPrefix(streamed), full != streamed { events.append(.textDelta(String(full.dropFirst(streamed.count)))) }
            }
        }
        let usage = response["usage"]
        inputTokens = usage["input_tokens"].int ?? inputTokens
        outputTokens = usage["output_tokens"].int ?? outputTokens
        reasoningTokens = usage["output_tokens_details"]["reasoning_tokens"].int ?? reasoningTokens
        cacheReadTokens = usage["input_tokens_details"]["cached_tokens"].int ?? cacheReadTokens
        let hasCalls = reducer.blocks.contains { if case .toolCall = $0.content { return true }; return false }
        stopReason = limited ? .maxTokens : hasCalls ? .toolUse : .endTurn
        rawStopReason = limited ? "max_output_tokens" : "completed"
        terminal = true
    }
}

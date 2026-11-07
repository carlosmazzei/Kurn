import Foundation

struct AgentResponsesAccumulator {
    struct Call {
        var itemID = ""
        var id = ""
        var name = ""
        var raw = ""
        var complete = false
    }

    var text = ""
    var calls: [Int: Call] = [:]
    var reasoning: [Int: JSONValue] = [:]
    var refusals: [String: String] = [:]
    var terminal = false
    var limited = false
    var usage: AgentUsage?
    var failure: AgentWireError?

    mutating func consume(_ value: JSONValue) throws -> [AgentModelEvent] {
        guard !terminal else { return [] }
        switch value["type"].string {
        case "response.output_text.delta":
            guard let delta = value["delta"].string, !delta.isEmpty else { return [] }
            text += delta
            return [.textDelta(delta)]
        case "response.refusal.delta":
            let key = "\(value["output_index"].int ?? 0):\(value["content_index"].int ?? 0)"
            return appendRefusal(value["delta"].string ?? "", key: key)
        case "response.output_item.added", "response.output_item.done":
            if let index = value["output_index"].int {
                record(value["item"], index: index, complete: value["type"].string == "response.output_item.done")
            }
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            let index = value["output_index"].int ?? calls.first(where: { $0.value.itemID == value["item_id"].string })?.key
            if let index {
                var call = calls[index] ?? Call()
                if value["type"].string == "response.function_call_arguments.done" {
                    call.raw = value["arguments"].string ?? call.raw
                    call.complete = value["arguments"].string != nil
                } else {
                    call.raw += value["delta"].string ?? ""
                }
                calls[index] = call
            }
        case "response.completed", "response.incomplete":
            return try finish(value)
        case "response.failed":
            try fail(value["response"]["error"]["message"].string ?? "Response failed")
        case "error":
            try fail(value["message"].string ?? "Stream error")
        default: break
        }
        return []
    }

    mutating func finish(_ value: JSONValue) throws -> [AgentModelEvent] {
        let response = value["response"]
        terminal = true
        if value["type"].string == "response.incomplete" {
            let reason = response["incomplete_details"]["reason"].string ?? "unknown"
            guard reason == "max_output_tokens" else { try fail("Incomplete response: \(reason)") }
            limited = true
        } else {
            for (index, item) in response["output"].array.enumerated() {
                record(item, index: index, complete: true)
            }
        }
        let reported = response["usage"]
        if reported["input_tokens"].int != nil || reported["output_tokens"].int != nil {
            usage = AgentUsage(inputTokens: reported["input_tokens"].int ?? 0, outputTokens: reported["output_tokens"].int ?? 0)
        }
        var events: [AgentModelEvent] = []
        for (index, item) in response["output"].array.enumerated() where item["type"].string == "message" {
            for (contentIndex, content) in item["content"].array.enumerated() where content["type"].string == "refusal" {
                let key = "\(index):\(contentIndex)"
                let full = content["refusal"].string ?? ""
                let streamed = refusals[key] ?? ""
                if full.hasPrefix(streamed) {
                    events += appendRefusal(String(full.dropFirst(streamed.count)), key: key)
                }
            }
        }
        return events
    }

    mutating func appendRefusal(_ delta: String, key: String) -> [AgentModelEvent] {
        guard !delta.isEmpty else { return [] }
        refusals[key, default: ""] += delta
        text += delta
        return [.textDelta(delta)]
    }

    mutating func record(_ item: JSONValue, index: Int, complete: Bool) {
        if item["type"].string == "reasoning" {
            reasoning[index] = item
            return
        }
        guard item["type"].string == "function_call" else { return }
        var call = calls[index] ?? Call()
        call.itemID = item["id"].string ?? call.itemID
        call.id = item["call_id"].string ?? call.id
        call.name = item["name"].string ?? call.name
        call.raw = item["arguments"].string ?? call.raw
        call.complete = complete && item["status"].string != "in_progress" && item["status"].string != "incomplete"
        calls[index] = call
    }

    mutating func fail(_ message: String) throws -> Never {
        terminal = true
        let error = AgentWireError.remote(message)
        failure = error
        throw error
    }

    func response() throws -> AgentTurnResponse {
        if let failure { throw failure }
        guard terminal else {
            if text.isEmpty && calls.isEmpty { throw AgentWireError.emptyResponse }
            throw AgentWireError.incompleteStream
        }
        let toolCalls: [AgentToolCall] = try (limited ? [] : calls.keys.sorted()).map { index in
            let call = calls[index] ?? Call()
            guard call.complete, !call.id.isEmpty, !call.name.isEmpty, !call.raw.isEmpty else {
                throw AgentWireError.incompleteToolCall
            }
            return AgentToolCall(id: call.id, name: call.name, arguments: (try? JSONValue.parse(call.raw)) ?? .null, rawArguments: call.raw)
        }
        guard !text.isEmpty || !toolCalls.isEmpty || limited else { throw AgentWireError.emptyResponse }
        let metadata: JSONValue? = reasoning.isEmpty ? nil : .object([
            "openAIResponses": .object(["reasoning": .array(reasoning.keys.sorted().compactMap { reasoning[$0] })])
        ])
        return AgentTurnResponse(text: text, toolCalls: toolCalls, usage: usage,
                                 stopReason: limited ? .maxTokens : toolCalls.isEmpty ? .endTurn : .toolUse,
                                 providerMetadata: metadata)
    }
}

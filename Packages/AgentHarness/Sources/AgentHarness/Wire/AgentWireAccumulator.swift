import Foundation

public enum AgentWireError: Error, Sendable, Equatable {
    case remote(String)
    case invalidResponse
    case emptyResponse
    case incompleteToolCall
    case incompleteStream
}

/// Consumes SSE data payloads, not SSE framing. State is protected by `lock`.
public final class AgentWireAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentWireState

    public init(format: AgentWireFormat, callIDPrefix: String = UUID().uuidString) {
        state = AgentWireState(format: format, callIDPrefix: callIDPrefix)
    }

    public func consume(_ payload: String) throws -> [AgentModelEvent] {
        try lock.withLock { try state.consume(payload) }
    }

    public func response() throws -> AgentTurnResponse {
        try lock.withLock { try state.response() }
    }
}

private struct AgentWireState {
    struct PartialCall {
        var id = ""
        var name = ""
        var raw = ""
        var initial: JSONValue = .object([:])
        var metadata: JSONValue?
    }

    let format: AgentWireFormat
    let callIDPrefix: String
    var text = ""
    var calls: [Int: PartialCall] = [:]
    var inputTokens: Int?
    var outputTokens: Int?
    var stopReason: AgentModelStopReason = .other("unknown")
    var receivedTerminal = false
    var responses = AgentResponsesAccumulator()

    mutating func consume(_ payload: String) throws -> [AgentModelEvent] {
        guard let value = try? JSONValue.parse(payload), case .object = value else { return [] }
        if case .object = value["error"] {
            throw AgentWireError.remote(value["error"]["message"].string ?? "Stream error")
        }
        switch format {
        case .anthropic: return try anthropic(value)
        case .openAI: return openAI(value)
        case .gemini: return gemini(value)
        case .openAIResponses: return try responses.consume(value)
        }
    }

    func response() throws -> AgentTurnResponse {
        if format == .openAIResponses { return try responses.response() }
        guard !text.isEmpty || !calls.isEmpty || stopReason == .maxTokens else { throw AgentWireError.emptyResponse }
        guard receivedTerminal else { throw AgentWireError.incompleteStream }
        let callIndices = stopReason == .maxTokens ? [] : calls.keys.sorted()
        let toolCalls = try callIndices.map { index in
            let call = calls[index] ?? PartialCall()
            guard !call.id.isEmpty, !call.name.isEmpty else { throw AgentWireError.incompleteToolCall }
            let raw = call.raw.isEmpty ? try call.initial.encodedString() : call.raw
            return AgentToolCall(id: call.id, name: call.name, arguments: (try? JSONValue.parse(raw)) ?? .null,
                                 rawArguments: raw, providerMetadata: call.metadata)
        }
        let usage = inputTokens == nil && outputTokens == nil ? nil
            : AgentUsage(inputTokens: inputTokens ?? 0, outputTokens: outputTokens ?? 0)
        return AgentTurnResponse(text: text, toolCalls: toolCalls, usage: usage, stopReason: stopReason)
    }

    mutating func appendText(_ delta: String?) -> [AgentModelEvent] {
        guard let delta, !delta.isEmpty else { return [] }
        text += delta
        return [.textDelta(delta)]
    }

    mutating func anthropic(_ value: JSONValue) throws -> [AgentModelEvent] {
        switch value["type"].string {
        case "error": throw AgentWireError.remote(value["error"]["message"].string ?? "Stream error")
        case "message_start":
            let usage = value["message"]["usage"]
            inputTokens = usage["input_tokens"].int
            outputTokens = usage["output_tokens"].int
        case "content_block_start":
            let block = value["content_block"]
            if block["type"].string == "tool_use", let index = value["index"].int {
                calls[index] = PartialCall(id: block["id"].string ?? "", name: block["name"].string ?? "",
                                           initial: block["input"] == .null ? .object([:]) : block["input"])
            }
            if block["type"].string == "text" { return appendText(block["text"].string) }
        case "content_block_delta":
            return anthropicDelta(value)
        case "message_delta":
            anthropicFinish(value)
        case "message_stop":
            if !receivedTerminal { stopReason = calls.isEmpty ? .endTurn : .toolUse }
            receivedTerminal = true
        default: break
        }
        return []
    }

    mutating func anthropicDelta(_ value: JSONValue) -> [AgentModelEvent] {
        let delta = value["delta"]
        if delta["type"].string == "text_delta" { return appendText(delta["text"].string) }
        if delta["type"].string == "input_json_delta", let index = value["index"].int, calls[index] != nil {
            calls[index]?.raw += delta["partial_json"].string ?? ""
        }
        return []
    }

    mutating func anthropicFinish(_ value: JSONValue) {
        if let input = value["usage"]["input_tokens"].int { inputTokens = input }
        if let output = value["usage"]["output_tokens"].int { outputTokens = output }
        guard let reason = value["delta"]["stop_reason"].string else { return }
        receivedTerminal = true
        switch reason {
        case "end_turn", "stop_sequence": stopReason = .endTurn
        case "tool_use": stopReason = .toolUse
        case "max_tokens": stopReason = .maxTokens
        default: stopReason = .other(reason)
        }
    }

    mutating func openAI(_ value: JSONValue) -> [AgentModelEvent] {
        let usage = value["usage"]
        if let input = usage["prompt_tokens"].int { inputTokens = input }
        if let output = usage["completion_tokens"].int { outputTokens = output }
        guard let choice = value["choices"].array.first(where: { ($0["index"].int ?? 0) == 0 }) else { return [] }
        let delta = choice["delta"]
        for fragment in delta["tool_calls"].array {
            guard let index = fragment["index"].int else { continue }
            var call = calls[index] ?? PartialCall()
            if let id = fragment["id"].string { call.id = id }
            call.name += fragment["function"]["name"].string ?? ""
            call.raw += fragment["function"]["arguments"].string ?? ""
            calls[index] = call
        }
        if let reason = choice["finish_reason"].string {
            receivedTerminal = true
            switch reason {
            case "stop": stopReason = .endTurn
            case "tool_calls", "function_call": stopReason = .toolUse
            case "length": stopReason = .maxTokens
            default: stopReason = .other(reason)
            }
        }
        return appendText(delta["content"].string)
    }

    mutating func gemini(_ value: JSONValue) -> [AgentModelEvent] {
        let usage = value["usageMetadata"]
        if let input = usage["promptTokenCount"].int { inputTokens = input }
        if let output = usage["candidatesTokenCount"].int {
            outputTokens = output + (usage["thoughtsTokenCount"].int ?? 0)
        }
        guard let candidate = value["candidates"].array.first(where: { ($0["index"].int ?? 0) == 0 }) else { return [] }
        var events: [AgentModelEvent] = []
        for part in candidate["content"]["parts"].array {
            if part["thought"] != .bool(true) { events += appendText(part["text"].string) }
            let function = part["functionCall"]
            guard let name = function["name"].string else { continue }
            let index = calls.count
            let id = function["id"].string
            var metadata: [String: JSONValue] = [:]
            if let id { metadata["geminiID"] = .string(id) }
            if let signature = part["thoughtSignature"].string { metadata["thoughtSignature"] = .string(signature) }
            calls[index] = PartialCall(id: id ?? "\(callIDPrefix)-\(index)", name: name,
                                      initial: function["args"] == .null ? .object([:]) : function["args"],
                                      metadata: metadata.isEmpty ? nil : .object(metadata))
        }
        if let reason = candidate["finishReason"].string {
            receivedTerminal = true
            switch reason {
            case "STOP": stopReason = calls.isEmpty ? .endTurn : .toolUse
            case "MAX_TOKENS": stopReason = .maxTokens
            default: stopReason = .other(reason)
            }
        }
        return events
    }
}

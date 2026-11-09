import Foundation

public enum AgentWireError: Error, Sendable, Equatable {
    case remote(String)
    case invalidResponse, emptyResponse, incompleteToolCall, incompleteStream, bufferLimit, deferred
}

/// SSE data payloads only. A failure is sticky; response() can never salvage a failed stream.
public final class AgentWireAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentWireState
    private var failure: AgentWireError?

    public init(format: AgentWireFormat, callIDPrefix: String = UUID().uuidString,
                messageID: String = UUID().uuidString, requestID: String = UUID().uuidString,
                timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) {
        state = AgentWireState(format: format, callIDPrefix: callIDPrefix, messageID: messageID,
                               requestID: requestID, timestampMilliseconds: timestampMilliseconds)
    }

    public func consume(_ payload: String) throws -> [AgentModelEvent] {
        try lock.withLock {
            if let failure { throw failure }
            do { return try state.consume(payload) }
            catch {
                let problem = (error as? AgentWireError) ?? (error is AgentContentError ? .bufferLimit : .invalidResponse)
                failure = problem
                throw problem
            }
        }
    }

    public func response() throws -> AgentTurnResponse {
        try lock.withLock {
            if let failure { throw failure }
            do { return try state.response() }
            catch is AgentContentError { throw AgentWireError.invalidResponse }
        }
    }
}

struct AgentWireState {
    let format: AgentWireFormat
    let callIDPrefix: String
    let messageID: String
    let requestID: String
    let timestampMilliseconds: Int64
    var model: String?
    var responseID: String?
    var rawStopReason: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var stopReason: AgentModelStopReason = .other("unknown")
    var terminal = false
    var anthropicStopReceived = false
    var reducer = AgentMessageReducer()
    var slots: [String: Int] = [:]
    var nextSlot = 0
    var chatCallBase: Int?
    var lastChatKind: String?
    var lastChatSlot: Int?
    var geminiOutputTokens: Int?
    var lastGeminiKind: String?
    var lastGeminiSlot: Int?
    var responsesReasoning: [Int: JSONValue] = [:]
    var responsesCalls: [String: Int] = [:]
    var responsesSlotIDs: [Int: String] = [:]
    var responsesKnownIDs: [String: String] = [:]
    var responsesItemIDs: [Int: String] = [:]
    var events: [AgentModelEvent] = []

    mutating func consume(_ payload: String) throws -> [AgentModelEvent] {
        events = []
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, payload != "[DONE]" else { return [] }
        if terminal {
            if payload.utf8.count <= 8 * 1_024 * 1_024, let value = try? JSONValue.parse(payload) {
                if format == .openAI { openAIUsage(value["usage"]) }
                if format == .gemini { geminiUsage(value["usageMetadata"]) }
            }
            return []
        }
        guard payload.utf8.count <= 8 * 1_024 * 1_024 else { throw AgentWireError.bufferLimit }
        guard let value = try? JSONValue.parse(payload), case .object = value else { throw AgentWireError.invalidResponse }
        if case .object = value["error"] { throw AgentWireError.remote(value["error"]["message"].string ?? "Stream error") }
        switch format {
        case .anthropic: try anthropic(value)
        case .openAI: try openAI(value)
        case .gemini: try gemini(value)
        case .openAIResponses: try responses(value)
        }
        return events
    }

    var usage: AgentUsage? {
        inputTokens == nil && outputTokens == nil ? nil
            : AgentUsage(inputTokens: inputTokens ?? 0, outputTokens: outputTokens ?? 0, reasoningTokens: reasoningTokens)
    }

    var api: String {
        switch format { case .anthropic: "anthropic"; case .openAI: "openAI"; case .openAIResponses: "openAIResponses"; case .gemini: "gemini" }
    }

    func response() throws -> AgentTurnResponse {
        var auditIDs = Set<String>()
        let blocks = reducer.blocks.map { block -> AgentContentBlock in
            guard !stopReason.permitsToolExecution, case .toolCall(let call, let complete) = block.content else { return block }
            if !call.id.isEmpty, auditIDs.insert(call.id).inserted { return block }
            var metadata: [String: JSONValue] = [:]
            if case .object(let original) = call.providerMetadata { metadata = original }
            metadata["originalCallID"] = .string(call.id)
            let audit = AgentToolCall(id: "\(callIDPrefix)-\(block.id)", name: call.name, arguments: call.arguments,
                rawArguments: call.rawArguments, providerMetadata: .object(metadata))
            return AgentContentBlock(id: block.id, content: .toolCall(audit, complete: complete))
        }
        let meaningful = blocks.contains { block in
            switch block.content { case .text(let text, _): return !text.isEmpty; case .toolCall, .image: return true; case .thinking: return false }
        }
        let allowsEmpty: Bool
        switch stopReason { case .maxTokens, .deferred, .error, .aborted: allowsEmpty = true; default: allowsEmpty = false }
        guard meaningful || allowsEmpty else { throw AgentWireError.emptyResponse }
        guard terminal else { throw AgentWireError.incompleteStream }
        let calls = blocks.compactMap { block -> AgentToolCall? in
            if case .toolCall(let call, _) = block.content { return call }; return nil
        }
        if stopReason.permitsToolExecution {
            guard blocks.allSatisfy({ if case .toolCall(let call, let complete) = $0.content {
                return complete && !call.id.isEmpty && !call.name.isEmpty
            }; return true }), Set(calls.map(\.id)).count == calls.count else { throw AgentWireError.incompleteToolCall }
        }
        let metadata: JSONValue? = responsesReasoning.isEmpty ? nil : .object([
            "openAIResponses": .object(["reasoning": .array(responsesReasoning.keys.sorted().compactMap { responsesReasoning[$0] })])])
        let identity = AgentResponseIdentity(api: api, model: model, responseID: responseID, requestID: requestID)
        let fullMetadata: JSONValue? = rawStopReason.map { .object(["rawStopReason": .string($0)]) }
        let message = try AgentContentMessage(id: messageID, timestampMilliseconds: timestampMilliseconds, role: .assistant,
            blocks: blocks, identity: identity, stopReason: stopReason, usage: usage, providerMetadata: fullMetadata)
        return AgentTurnResponse(text: message.text, usage: usage, stopReason: stopReason, providerMetadata: metadata,
                                 discardedToolCalls: stopReason == .maxTokens ? calls.count : 0, message: message)
    }

    func blockID(_ slot: Int) -> String { responsesSlotIDs[slot] ?? "b\(slot)" }
    func block(_ slot: Int) -> AgentContentBlock? { reducer.blocks.first { $0.id == blockID(slot) } }

    mutating func start(_ slot: Int, _ content: AgentContentBlock.Content) throws {
        guard slot >= 0, slot < 4_096 * 4_096 else { throw AgentWireError.invalidResponse }
        let event = AgentContentEvent.blockStarted(index: slot, block: AgentContentBlock(id: blockID(slot), content: content))
        try emit(event)
    }

    mutating func update(_ slot: Int, _ content: AgentContentBlock.Content) throws {
        try emit(.blockUpdated(AgentContentBlock(id: blockID(slot), content: content)))
    }

    mutating func delta(_ slot: Int, _ delta: AgentContentDelta) throws { try emit(.blockDelta(id: blockID(slot), delta: delta)) }

    mutating func emit(_ event: AgentContentEvent) throws {
        try reducer.apply(event)
        events.append(.content(event))
    }

    mutating func text(_ text: String?, slot: Int, thinking: Bool = false) throws {
        guard let text, !text.isEmpty else { return }
        if block(slot) == nil { try start(slot, thinking ? .thinking(text: "", signature: nil, redacted: false) : .text("")) }
        try delta(slot, thinking ? .thinking(text) : .text(text))
        if !thinking { events.append(.textDelta(text)) }
    }

    mutating func allocated(_ key: String) -> Int {
        if let slot = slots[key] { return slot }
        let slot = nextSlot
        nextSlot += 1
        slots[key] = slot
        return slot
    }

    mutating func finishCalls() throws {
        for block in reducer.blocks {
            guard case .toolCall(let call, _) = block.content else { continue }
            let raw = call.rawArguments.isEmpty ? "{}" : call.rawArguments
            let final = AgentToolCall(id: call.id, name: call.name, arguments: (try? JSONValue.parse(raw)) ?? .null,
                                      rawArguments: raw, providerMetadata: call.providerMetadata)
            try emit(.blockUpdated(AgentContentBlock(id: block.id, content: .toolCall(final, complete: true))))
        }
    }
}

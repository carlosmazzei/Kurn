import Foundation

public enum AgentStreamFailure: String, Codable, Sendable { case preparation, transport, invalidStream, cancelled, deferred }

public enum AgentContentEvent: Sendable, Equatable {
    case blockStarted(index: Int, block: AgentContentBlock)
    case blockDelta(id: String, delta: AgentContentDelta)
    case blockUpdated(AgentContentBlock)
    case messageFinished(AgentContentMessage)
    case failed(AgentStreamFailure)
}

public enum AgentContentDelta: Sendable, Equatable {
    case text(String), thinking(String), signature(String)
    case toolCall(id: String?, name: String?, arguments: String?)
}

/// An ordered bounded projection. A final snapshot replaces all intermediate blocks and usage.
/// Thinking and raw arguments are content, never public diagnostic text.
public struct AgentMessageReducer: Sendable {
    public private(set) var blocks: [AgentContentBlock] = []
    public private(set) var finalMessage: AgentContentMessage?
    public private(set) var failure: AgentStreamFailure?
    private var indices: [String: Int] = [:]
    private var sizes: [String: Int] = [:]
    private var byteCount = 0
    private let maxBytes: Int
    public var isTerminal: Bool { finalMessage != nil || failure != nil }

    public init(maxBytes: Int = 8 * 1_024 * 1_024) { self.maxBytes = max(1, maxBytes) }

    public mutating func apply(_ event: AgentContentEvent) throws {
        guard !isTerminal else { return }
        var candidate = blocks
        switch event {
        case .blockStarted(let index, let block):
            guard index >= 0, indices[block.id] == nil, !indices.values.contains(index), AgentContentMessage.validID(block.id)
            else { throw AgentContentError.invalidTransition }
            var nextIndices = indices
            nextIndices[block.id] = index
            candidate.append(block)
            candidate.sort { nextIndices[$0.id, default: 0] < nextIndices[$1.id, default: 0] }
            try reserve(id: block.id, bytes: Self.size(block), count: candidate.count)
            indices = nextIndices
        case .blockDelta(let id, let delta):
            guard let index = candidate.firstIndex(where: { $0.id == id }) else { throw AgentContentError.unknownBlock }
            let block = candidate[index]
            let content: AgentContentBlock.Content
            let added: Int
            switch (block.content, delta) {
            case (.text(let text, let signature), .text(let value)):
                content = .text(text + value, signature: signature); added = value.utf8.count
            case (.thinking(let text, let signature, _, let metadata), .thinking(let value)):
                content = .thinking(text: (text ?? "") + value, signature: signature, redacted: false, metadata: metadata)
                added = value.utf8.count
            case (.thinking(let text, let signature, let redacted, let metadata), .signature(let value)):
                content = .thinking(text: text, signature: (signature ?? "") + value, redacted: redacted, metadata: metadata)
                added = value.utf8.count
            case (.toolCall(let call, false), .toolCall(let id, let name, let arguments)):
                let raw = call.rawArguments + (arguments ?? "")
                content = .toolCall(AgentToolCall(id: id ?? call.id, name: call.name + (name ?? ""),
                    arguments: .null, rawArguments: raw, providerMetadata: call.providerMetadata, namespace: call.namespace, invocationID: call.invocationID), complete: false)
                added = (id?.utf8.count ?? 0) + (name?.utf8.count ?? 0) + (arguments?.utf8.count ?? 0)
            default: throw AgentContentError.invalidTransition
            }
            try reserve(id: id, bytes: sizes[id, default: 0] + added, count: candidate.count)
            candidate[index] = AgentContentBlock(id: id, content: content)
        case .blockUpdated(let block):
            guard let index = candidate.firstIndex(where: { $0.id == block.id }) else { throw AgentContentError.unknownBlock }
            candidate[index] = block
            try reserve(id: block.id, bytes: Self.size(block), count: candidate.count)
        case .messageFinished(let message):
            guard message.blocks.count <= 4_096, message.blocks.reduce(0, { $0 + Self.size($1) }) <= maxBytes
            else { throw AgentContentError.bufferLimit }
            finalMessage = message
            candidate = message.blocks
        case .failed(let error): failure = error
        }
        blocks = candidate
    }

    private mutating func reserve(id: String, bytes: Int, count: Int) throws {
        let next = byteCount - sizes[id, default: 0] + bytes
        guard count <= 4_096, next <= maxBytes else { throw AgentContentError.bufferLimit }
        byteCount = next
        sizes[id] = bytes
    }

    private static func size(_ block: AgentContentBlock) -> Int {
        // Data/arguments/replay metadata are bounded too. Encode only replacement blocks, not
        // the accumulated transcript for every text delta.
        (try? JSONEncoder().encode(block).count) ?? Int.max / 8
    }
}

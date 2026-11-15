import Foundation

/// Native v1 messages are independent of persisted session entries and UI turns.
public struct AgentContentMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let contractVersion: Int
    public let id: String
    /// Unix milliseconds, never Foundation's seconds-since-2001 Date codec.
    public let timestampMilliseconds: Int64?
    public let role: Role
    public private(set) var blocks: [AgentContentBlock]
    public let identity: AgentResponseIdentity?
    public let stopReason: AgentModelStopReason?
    public let usage: AgentUsage?
    public let providerMetadata: JSONValue?

    public init(id: String, timestampMilliseconds: Int64?, role: Role, blocks: [AgentContentBlock],
                identity: AgentResponseIdentity? = nil, stopReason: AgentModelStopReason? = nil,
                usage: AgentUsage? = nil, providerMetadata: JSONValue? = nil) throws {
        guard Self.validID(id), Set(blocks.map(\.id)).count == blocks.count,
              blocks.count <= 4_096, blocks.allSatisfy({ Self.validID($0.id) && Self.validContent($0.content) }),
              Self.validCalls(blocks), Self.validIdentity(identity),
              try JSONEncoder().encode(blocks).count + JSONEncoder().encode(providerMetadata).count
                  + JSONEncoder().encode(identity).count <= 8 * 1_024 * 1_024,
              role == .assistant || blocks.allSatisfy({ if case .text = $0.content { return true }; if case .image = $0.content { return true }; return false })
        else { throw AgentContentError.invalidMessage }
        contractVersion = 1
        self.id = id
        self.timestampMilliseconds = timestampMilliseconds
        self.role = role
        self.blocks = blocks
        self.identity = identity
        self.stopReason = stopReason
        self.usage = usage
        self.providerMetadata = providerMetadata
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        guard try value.decode(Int.self, forKey: .contractVersion) == 1 else { throw AgentContentError.unsupportedVersion }
        try self.init(id: value.decode(String.self, forKey: .id),
                      timestampMilliseconds: value.decodeIfPresent(Int64.self, forKey: .timestampMilliseconds),
                      role: value.decode(Role.self, forKey: .role), blocks: value.decode([AgentContentBlock].self, forKey: .blocks),
                      identity: value.decodeIfPresent(AgentResponseIdentity.self, forKey: .identity),
                      stopReason: value.decodeIfPresent(AgentModelStopReason.self, forKey: .stopReason),
                      usage: value.decodeIfPresent(AgentUsage.self, forKey: .usage),
                      providerMetadata: value.decodeIfPresent(JSONValue.self, forKey: .providerMetadata))
    }

    /// Internal disposable request copy. Only invocation IDs/arguments/metadata change; the
    /// validated message/block identities, roles and original stored content remain untouched.
    func projectingToolCalls(_ transform: (AgentToolCall, Bool) -> AgentToolCall) -> Self {
        var copy = self
        copy.blocks = blocks.map { block in
            guard case .toolCall(let call, let complete) = block.content else { return block }
            return AgentContentBlock(id: block.id, content: .toolCall(transform(call, complete), complete: complete))
        }
        return copy
    }

    public var text: String { blocks.compactMap { if case .text(let text, _) = $0.content { return text }; return nil }.joined() }
    public var toolCalls: [AgentToolCall] { blocks.compactMap { if case .toolCall(let call, _) = $0.content { return call }; return nil } }
    public var hasIncompleteCalls: Bool { blocks.contains { if case .toolCall(_, false) = $0.content { return true }; return false } }
    static func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 128 }

    private static func validCalls(_ blocks: [AgentContentBlock]) -> Bool {
        let ids = blocks.compactMap { if case .toolCall(let call, _) = $0.content { return call.id }; return nil }
        let invocations = blocks.compactMap { if case .toolCall(let call, _) = $0.content { return call.invocationID }; return nil }
        return Set(ids).count == ids.count && Set(invocations).count == invocations.count
    }

    private static func validIdentity(_ identity: AgentResponseIdentity?) -> Bool {
        guard let identity else { return true }
        return validID(identity.requestID) && (identity.api.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
            && (identity.responseID.map(validID) ?? true) && (identity.model?.utf8.count ?? 0) <= 512
    }

    private static func validContent(_ content: AgentContentBlock.Content) -> Bool {
        switch content {
        case .toolCall(let call, _):
            return validID(call.id) && call.name.utf8.count <= 256
                && (call.namespace.map(validID) ?? true) && (call.invocationID.map(validID) ?? true)
        case .image(let mime, let data):
            return mime.hasPrefix("image/") && data.utf8.count <= 8 * 1_024 * 1_024 && !data.isEmpty && Data(base64Encoded: data) != nil
        default: return true
        }
    }
}

public struct AgentResponseIdentity: Codable, Sendable, Equatable {
    public let api: String?
    public let model: String?
    public let responseID: String?
    public let requestID: String

    public init(api: String? = nil, model: String? = nil, responseID: String? = nil, requestID: String) {
        self.api = api
        self.model = model
        self.responseID = responseID
        self.requestID = requestID
    }
}

public struct AgentContentBlock: Codable, Sendable, Equatable {
    public enum Content: Codable, Sendable, Equatable {
        case text(String, signature: String? = nil)
        case thinking(text: String?, signature: String?, redacted: Bool, metadata: JSONValue? = nil)
        /// Complete is a protocol fact, independent of whether rawArguments parses.
        case toolCall(AgentToolCall, complete: Bool)
        case image(mimeType: String, base64: String)
    }
    public let id: String
    public let content: Content

    public init(id: String, content: Content) { self.id = id; self.content = content }
}

public enum AgentContentError: Error, Sendable, Equatable {
    case unsupportedVersion, invalidMessage, invalidTransition, unknownBlock, bufferLimit
}

public enum AgentToolArgumentError: String, Codable, Sendable { case invalidJSON, nonObject }

extension AgentToolCall {
    public var argumentError: AgentToolArgumentError? {
        guard let value = try? JSONValue.parse(rawArguments) else { return .invalidJSON }
        guard case .object = value else { return .nonObject }
        return nil
    }

    /// Parsed provider data is never evidence that a salvaged raw argument string was valid.
    public var hasValidArguments: Bool {
        argumentError == nil
    }
}

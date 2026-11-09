import Foundation

/// A local invocation is distinct from the provider's call ID, which may recur on another request.
public struct AgentToolInvocation: Codable, Sendable, Equatable {
    public let id: String
    public let requestID: String
    public let callID: String
    public let toolName: String
    public let namespace: String?

    public init(id: String, requestID: String, callID: String, toolName: String, namespace: String? = nil) throws {
        guard [id, requestID, callID].allSatisfy(AgentContentMessage.validID), toolName.utf8.count <= 256,
              namespace.map({ AgentContentMessage.validID($0) }) ?? true else { throw AgentContentError.invalidMessage }
        self.id = id; self.requestID = requestID; self.callID = callID; self.toolName = toolName; self.namespace = namespace
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: value.decode(String.self, forKey: .id), requestID: value.decode(String.self, forKey: .requestID),
            callID: value.decode(String.self, forKey: .callID), toolName: value.decode(String.self, forKey: .toolName),
            namespace: value.decodeIfPresent(String.self, forKey: .namespace))
    }
}

public enum AgentToolBlockReason: String, Codable, Sendable {
    case outputLimit, toolsDisabled, turnLimit, toolCallLimit, costLimit
    case invalidArguments, unknownTool, unsupportedNamespace, confirmationDeclined, interruptedResponse, policyDenied
}

/// Native tool output is a message, not a model event, diagnostic preview or effect receipt.
public struct AgentToolResultMessage: Codable, Sendable, Equatable {
    public let contractVersion: Int
    public let id: String
    public let timestampMilliseconds: Int64?
    public let invocation: AgentToolInvocation
    public let blocks: [AgentContentBlock]
    public let isError: Bool
    public let syntheticReason: AgentToolBlockReason?
    public let details: JSONValue?
    public let structuredContent: JSONValue?

    public init(id: String, timestampMilliseconds: Int64?, invocation: AgentToolInvocation, blocks: [AgentContentBlock],
                isError: Bool, syntheticReason: AgentToolBlockReason? = nil, details: JSONValue? = nil, structuredContent: JSONValue? = nil) throws {
        guard AgentContentMessage.validID(id), blocks.count <= 4_096,
              Set(blocks.map(\.id)).count == blocks.count,
              blocks.allSatisfy({ AgentContentMessage.validID($0.id) && Self.validContent($0.content) }),
              syntheticReason == nil || isError,
              try JSONEncoder().encode(blocks).count + JSONEncoder().encode(details).count
                + JSONEncoder().encode(structuredContent).count <= 8 * 1_024 * 1_024
        else { throw AgentContentError.invalidMessage }
        contractVersion = 1
        self.id = id; self.timestampMilliseconds = timestampMilliseconds; self.invocation = invocation
        self.blocks = blocks; self.isError = isError; self.syntheticReason = syntheticReason; self.details = details
        self.structuredContent = structuredContent
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        guard try value.decode(Int.self, forKey: .contractVersion) == 1 else { throw AgentContentError.unsupportedVersion }
        try self.init(id: value.decode(String.self, forKey: .id),
            timestampMilliseconds: value.decodeIfPresent(Int64.self, forKey: .timestampMilliseconds),
            invocation: value.decode(AgentToolInvocation.self, forKey: .invocation),
            blocks: value.decode([AgentContentBlock].self, forKey: .blocks), isError: value.decode(Bool.self, forKey: .isError),
            syntheticReason: value.decodeIfPresent(AgentToolBlockReason.self, forKey: .syntheticReason),
            details: value.decodeIfPresent(JSONValue.self, forKey: .details),
            structuredContent: value.decodeIfPresent(JSONValue.self, forKey: .structuredContent))
    }

    public var text: String { blocks.compactMap { if case .text(let text, _) = $0.content { return text }; return nil }.joined() }

    private static func validContent(_ content: AgentContentBlock.Content) -> Bool {
        switch content {
        case .text: return true
        case .image(let mime, let data): return mime.hasPrefix("image/") && !data.isEmpty && Data(base64Encoded: data) != nil
        default: return false
        }
    }
}

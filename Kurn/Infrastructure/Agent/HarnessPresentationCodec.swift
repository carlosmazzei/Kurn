import AgentHarness
import Foundation
import KurnCore

/// Host metadata excludes message ID/role/text, which belong to the native message.
struct HarnessTurnMetadata: Codable {
    let usage: TokenUsage?
    let costUSD: Double?
    let elapsedSeconds: TimeInterval?
    let steps: [AgentRunStep]?
    let artifacts: [ChatArtifactReference]?
    let artifactOrigins: [UUID: ChatArtifactOrigin]?

    init(_ turn: PersistedChatTurn) {
        usage = turn.usage; costUSD = turn.costUSD; elapsedSeconds = turn.elapsedSeconds
        steps = turn.steps; artifacts = turn.artifacts; artifactOrigins = turn.artifactOrigins
    }
}

struct HarnessPresentationState: Codable {
    static let type = "kurn.presentation-state.v1"
    let scope: ChatSourceScope?
    let artifactRevisionIDs: [String]
}

enum HarnessPresentationCodec {
    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let result = JSONStorage.decodeAuthoritative(type, from: data).decodedValue else { throw AgentSessionStoreError.corruptPayload }
        return result
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        guard let data = JSONStorage.encodeAuthoritative(value) else { throw AgentSessionStoreError.corruptPayload }
        return data
    }
    static func message(_ turn: PersistedChatTurn) throws -> AgentMessage {
        let usage = turn.usage.map { AgentUsage(inputTokens: $0.promptTokens, outputTokens: $0.completionTokens) }
        return .content(try AgentContentMessage(id: turn.id.uuidString, timestampMilliseconds: nil,
            role: turn.role == .user ? .user : .assistant, blocks: [AgentContentBlock(id: "text", content: .text(turn.text))], usage: usage))
    }
    static func turn(_ entry: AgentSessionEntry) throws -> PersistedChatTurn {
        guard case .message(.content(let message)) = entry.payload, let id = UUID(uuidString: message.id),
              let metadata = entry.metadata else { throw AgentSessionStoreError.corruptPayload }
        let value = try JSONDecoder().decode(HarnessTurnMetadata.self, from: JSONEncoder().encode(metadata))
        return PersistedChatTurn(id: id, role: message.role == .user ? .user : .assistant, text: message.text,
            usage: value.usage, costUSD: value.costUSD, elapsedSeconds: value.elapsedSeconds, steps: value.steps,
            artifacts: value.artifacts, artifactOrigins: value.artifactOrigins)
    }
}

import Foundation

public enum AgentSessionStoreError: Error, Sendable, Equatable {
    case unsupportedVersion, invalidEntry, invalidGraph, conflict, notFound, corruptPayload
}

/// Append identity is independent of message identity and the selected leaf.
public struct AgentSessionEntry: Codable, Sendable, Equatable {
    public enum Payload: Codable, Sendable, Equatable {
        case message(AgentMessage)
        /// Bundled host metadata. Unknown types remain data and cannot execute code.
        case custom(type: String, data: JSONValue)
    }
    public let contractVersion: Int
    public let sessionID: String
    public let id: String
    public let parentID: String?
    public let ordinal: Int
    /// Explicit UTC ISO 8601 entry time; this is not the message's historical timestamp.
    public let createdAt: String
    public let payload: Payload
    public let metadata: JSONValue?

    public init(sessionID: String, id: String, parentID: String?, ordinal: Int, createdAt: String,
                payload: Payload, metadata: JSONValue? = nil) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: createdAt)
        guard [sessionID, id].allSatisfy(AgentContentMessage.validID), parentID.map(AgentContentMessage.validID) ?? true,
              parentID != id, ordinal > 0, createdAt.hasSuffix("Z"), date != nil,
              try JSONEncoder().encode(payload).count + JSONEncoder().encode(metadata).count <= 16 * 1_024 * 1_024
        else { throw AgentSessionStoreError.invalidEntry }
        switch payload {
        case .message(.content), .message(.tool): break
        case .message: throw AgentSessionStoreError.invalidEntry
        case .custom(let type, _):
            guard AgentContentMessage.validID(type) else { throw AgentSessionStoreError.invalidEntry }
        }
        contractVersion = 1
        self.sessionID = sessionID; self.id = id; self.parentID = parentID; self.ordinal = ordinal
        self.createdAt = createdAt; self.payload = payload; self.metadata = metadata
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        guard try value.decode(Int.self, forKey: .contractVersion) == 1 else { throw AgentSessionStoreError.unsupportedVersion }
        try self.init(sessionID: value.decode(String.self, forKey: .sessionID), id: value.decode(String.self, forKey: .id),
            parentID: value.decodeIfPresent(String.self, forKey: .parentID), ordinal: value.decode(Int.self, forKey: .ordinal),
            createdAt: value.decode(String.self, forKey: .createdAt), payload: value.decode(Payload.self, forKey: .payload),
            metadata: value.decodeIfPresent(JSONValue.self, forKey: .metadata))
    }

    public static func time(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Validates the whole append log, including siblings. A leaf can precede the newest append.
public struct AgentEntryGraph: Sendable {
    public let entries: [AgentSessionEntry]
    public let activePath: [AgentSessionEntry]

    public init(sessionID: String, entries: [AgentSessionEntry], leafID: String?) throws {
        let ordered = entries.sorted { $0.ordinal < $1.ordinal }
        var known: [String: AgentSessionEntry] = [:]
        for (offset, entry) in ordered.enumerated() {
            guard entry.sessionID == sessionID, entry.ordinal == offset + 1, known[entry.id] == nil,
                  entry.parentID.map({ known[$0] != nil }) ?? true else { throw AgentSessionStoreError.invalidGraph }
            known[entry.id] = entry
        }
        var path: [AgentSessionEntry] = []
        var cursor = leafID
        while let id = cursor {
            guard let entry = known[id] else { throw AgentSessionStoreError.invalidGraph }
            path.append(entry); cursor = entry.parentID
        }
        self.entries = ordered
        activePath = path.reversed()
    }
}

public struct AgentSessionSnapshot: Sendable {
    public let sessionID: String
    public let revision: Int
    public let leafID: String?
    public let entries: [AgentSessionEntry]
    public init(sessionID: String, revision: Int, leafID: String?, entries: [AgentSessionEntry]) {
        self.sessionID = sessionID; self.revision = revision; self.leafID = leafID; self.entries = entries
    }
}

public struct AgentSessionCommit: Sendable {
    public let sessionID: String
    public let expectedRevision: Int
    public let entries: [AgentSessionEntry]
    public let leafID: String?
    public init(sessionID: String, expectedRevision: Int, entries: [AgentSessionEntry], leafID: String?) {
        self.sessionID = sessionID; self.expectedRevision = expectedRevision; self.entries = entries; self.leafID = leafID
    }
}

/// Store adapters exchange values only. Lifecycle persistence barriers belong to the session owner.
public protocol AgentSessionStore: Sendable {
    func load(sessionID: String) async throws -> AgentSessionSnapshot
    func commit(_ group: AgentSessionCommit) async throws
}

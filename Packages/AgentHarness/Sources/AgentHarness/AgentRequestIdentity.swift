import Foundation

/// The owner assigns request identity before provider preparation. Retries and summaries get new IDs.
public struct AgentRequestIdentity: Codable, Sendable, Equatable {
    public enum Purpose: String, Codable, Sendable { case response, wrapUp, summary }
    public let id: String
    public let purpose: Purpose

    public init(purpose: Purpose = .response) { id = UUID().uuidString; self.purpose = purpose }
    public init(id: String, purpose: Purpose = .response) throws {
        guard AgentContentMessage.validID(id) else { throw AgentContentError.invalidMessage }
        self.id = id; self.purpose = purpose
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: value.decode(String.self, forKey: .id), purpose: value.decode(Purpose.self, forKey: .purpose))
    }
}

public struct AgentModelDescriptor: Sendable, Equatable {
    public let api: String
    public let model: String
    public init(api: String, model: String) { self.api = api; self.model = model }
}

/// An app supplies its conversation ID; a standalone run defaults to a new transient session.
public struct AgentRunContext: Sendable {
    public let sessionID: String
    public let runID: UUID

    public init(sessionID: UUID = UUID(), runID: UUID = UUID()) { self.sessionID = sessionID.uuidString; self.runID = runID }
    public init(sessionID: String, runID: UUID = UUID()) throws {
        guard AgentContentMessage.validID(sessionID) else { throw AgentContentError.invalidMessage }
        self.sessionID = sessionID; self.runID = runID
    }
}

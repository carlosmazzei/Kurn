import Foundation

/// Persisted metadata containers. They do not schedule queues, resume runs or prove an effect.
public struct AgentRecoveryRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case run, queue, draft, effect }
    public let contractVersion: Int
    public let id: String
    public let kind: Kind
    public let data: JSONValue

    public init(id: String, kind: Kind, data: JSONValue) throws {
        guard AgentContentMessage.validID(id), try JSONEncoder().encode(data).count <= 1_024 * 1_024 else {
            throw AgentSessionStoreError.invalidEntry
        }
        contractVersion = 1; self.id = id; self.kind = kind; self.data = data
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .contractVersion) == 1 else { throw AgentSessionStoreError.unsupportedVersion }
        try self.init(id: values.decode(String.self, forKey: .id), kind: values.decode(Kind.self, forKey: .kind),
                      data: values.decode(JSONValue.self, forKey: .data))
    }
}

import Foundation

/// Why content may be sent to a cloud provider. The app has one rule for every
/// feature: content reaches a provider only under a grant for that provider
/// and purpose (CLAUDE.md, "Cloud consent").
public enum CloudConsentPurpose: String, Codable, Sendable, CaseIterable {
    /// Sent only when the person asks: a summary, a chat question, a document,
    /// regenerating a title.
    case onRequest
    /// Sent without a request, once per recording: cloud transcription,
    /// automatic titles, the meeting wiki, correction, Knowledge extraction.
    case automatic
}

public struct CloudConsentGrant: Codable, Sendable, Hashable {
    /// The provider and the endpoint it was granted for; a changed endpoint
    /// is a different destination and needs a new grant.
    public let destination: String
    public let purpose: CloudConsentPurpose
    public let grantedAt: Date

    public init(destination: String, purpose: CloudConsentPurpose, grantedAt: Date) {
        self.destination = destination
        self.purpose = purpose
        self.grantedAt = grantedAt
    }
}

/// The grants a person gave, one per destination and purpose. An automatic
/// grant also covers on-request use: allowing content to leave without asking
/// implies allowing it when asked.
public struct CloudConsentLedger: Codable, Sendable, Equatable {
    public private(set) var version = 1
    public private(set) var grants: [CloudConsentGrant] = []

    public init() {}

    public static func destination(providerID: String, endpoint: String) -> String {
        "\(providerID)|\(endpoint)"
    }

    public func allows(_ destination: String, for purpose: CloudConsentPurpose) -> Bool {
        grants.contains { $0.destination == destination && ($0.purpose == purpose || $0.purpose == .automatic) }
    }

    public func grant(for destination: String, purpose: CloudConsentPurpose) -> CloudConsentGrant? {
        grants.first { $0.destination == destination && $0.purpose == purpose }
    }

    /// Destinations with at least one grant, in a stable order.
    public var destinations: [String] {
        Array(Set(grants.map(\.destination))).sorted()
    }

    public mutating func grant(_ destination: String, for purpose: CloudConsentPurpose, at date: Date) {
        guard grant(for: destination, purpose: purpose) == nil else { return }
        grants.append(CloudConsentGrant(destination: destination, purpose: purpose, grantedAt: date))
    }

    public mutating func revoke(_ destination: String, for purpose: CloudConsentPurpose) {
        grants.removeAll { $0.destination == destination && $0.purpose == purpose }
    }

    public mutating func revokeAll(_ destination: String) {
        grants.removeAll { $0.destination == destination }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Refuses a future version rather than reading it as fewer grants.
    public static func decode(_ data: Data) throws -> CloudConsentLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(CloudConsentLedger.self, from: data)
        guard ledger.version == 1 else { throw CloudConsentLedgerError.unsupportedVersion }
        return ledger
    }
}

public enum CloudConsentLedgerError: Error, Equatable {
    case unsupportedVersion
}

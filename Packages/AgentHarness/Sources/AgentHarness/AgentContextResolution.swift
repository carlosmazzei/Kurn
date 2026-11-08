import Foundation

/// Immutable evidence of the capacity actually used by a run. Cache is a delivery state,
/// not a different origin. This value is safe to persist beside conversation steps.
public struct AgentContextResolution: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable { case api, fixedTable = "fixed_table", fixedFallback = "fixed_fallback" }
    public enum LimitKind: String, Codable, Sendable { case combined, input }
    public enum Reason: String, Codable, Sendable {
        case reported, catalogMatch, unknownModel, expiredMetadata
    }

    public let id: UUID
    public let modelID: String
    public let contextWindowTokens: Int
    public let maxOutputTokens: Int?
    public let limitKind: LimitKind
    public let source: Source
    public let isCached: Bool
    public let resolvedAt: Date
    public let fetchedAt: Date?
    public let catalogVersion: String?
    public let reason: Reason

    public init(contextWindowTokens: Int, source: Source, reason: Reason, modelLimits: AgentModelLimits? = nil,
                catalogVersion: String? = nil, resolvedAt: Date = Date(), id: UUID = UUID(), modelID: String = "") {
        self.id = id
        self.modelID = modelID
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = modelLimits?.maxOutputTokens
        self.limitKind = modelLimits?.limitKind ?? .combined
        self.source = source
        self.isCached = source == .api && modelLimits != nil
        self.resolvedAt = resolvedAt
        self.fetchedAt = source == .api ? modelLimits?.fetchedAt : nil
        self.catalogVersion = catalogVersion
        self.reason = reason
    }
}

/// Metadata obtained from the configured provider. Optional fields are independent.
public struct AgentModelLimits: Codable, Sendable, Equatable {
    public let contextWindowTokens: Int?
    public let maxOutputTokens: Int?
    public let limitKind: AgentContextResolution.LimitKind
    public let fetchedAt: Date

    public init(contextWindowTokens: Int?, maxOutputTokens: Int? = nil,
                limitKind: AgentContextResolution.LimitKind = .combined, fetchedAt: Date = Date()) {
        self.contextWindowTokens = Self.valid(contextWindowTokens)
        self.maxOutputTokens = Self.valid(maxOutputTokens)
        self.limitKind = limitKind
        self.fetchedAt = fetchedAt
    }

    private static func valid(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= 100_000_000 else { return nil }
        return value
    }
}

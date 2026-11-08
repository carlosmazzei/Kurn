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
    public private(set) var isCached: Bool
    public let resolvedAt: Date
    public let fetchedAt: Date?
    public let catalogVersion: String?
    public let reason: Reason
    public private(set) var metadataRefresh: AgentMetadataRefresh?

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
        self.fetchedAt = source == .api ? modelLimits?.contextTimestamp : nil
        self.catalogVersion = catalogVersion
        self.reason = reason
        self.metadataRefresh = nil
    }

    public func recordingMetadataRefresh(_ status: AgentMetadataRefresh?) -> Self {
        var result = self
        result.metadataRefresh = status
        if source == .api && status == .fetched { result.isCached = false }
        return result
    }
}

/// Metadata obtained from the configured provider. Optional fields are independent.
public struct AgentModelLimits: Codable, Sendable, Equatable {
    public let contextWindowTokens: Int?
    public let maxOutputTokens: Int?
    public let limitKind: AgentContextResolution.LimitKind
    public let fetchedAt: Date
    public let contextFetchedAt: Date?
    public let outputFetchedAt: Date?
    public var contextTimestamp: Date { contextFetchedAt ?? fetchedAt }
    public var outputTimestamp: Date { outputFetchedAt ?? fetchedAt }

    public init(contextWindowTokens: Int?, maxOutputTokens: Int? = nil,
                limitKind: AgentContextResolution.LimitKind = .combined, fetchedAt: Date = Date(),
                contextFetchedAt: Date? = nil, outputFetchedAt: Date? = nil) {
        self.contextWindowTokens = Self.valid(contextWindowTokens)
        self.maxOutputTokens = Self.valid(maxOutputTokens)
        self.limitKind = limitKind
        self.fetchedAt = fetchedAt
        self.contextFetchedAt = contextFetchedAt
        self.outputFetchedAt = outputFetchedAt
    }

    private static func valid(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= 100_000_000 else { return nil }
        return value
    }
}

/// Metadata lookup outcome; deliberately contains no endpoint, credentials or error text.
public enum AgentMetadataRefresh: String, Codable, Sendable {
    case cacheFresh, fetched, notReported, unsupported, unavailable, failed, deferred
}

public extension AgentModelLimits {
    /// Merge independent fields without refreshing the age of a value the response omitted.
    func merging(_ next: AgentModelLimits, now: Date = Date()) -> AgentModelLimits {
        let contextRecovered = ModelContextWindows.isFresh(next.contextTimestamp, now: now)
            && !ModelContextWindows.isFresh(contextTimestamp, now: now)
        let contextComparable = ModelContextWindows.isFresh(next.contextTimestamp, now: now)
            == ModelContextWindows.isFresh(contextTimestamp, now: now)
        let outputRecovered = ModelContextWindows.isFresh(next.outputTimestamp, now: now)
            && !ModelContextWindows.isFresh(outputTimestamp, now: now)
        let outputComparable = ModelContextWindows.isFresh(next.outputTimestamp, now: now)
            == ModelContextWindows.isFresh(outputTimestamp, now: now)
        let newContext = next.contextWindowTokens != nil
            && (contextWindowTokens == nil || contextRecovered || (contextComparable && next.contextTimestamp >= contextTimestamp))
        let newOutput = next.maxOutputTokens != nil
            && (maxOutputTokens == nil || outputRecovered || (outputComparable && next.outputTimestamp >= outputTimestamp))
        return AgentModelLimits(contextWindowTokens: newContext ? next.contextWindowTokens : contextWindowTokens,
                                maxOutputTokens: newOutput ? next.maxOutputTokens : maxOutputTokens,
                                limitKind: newContext ? next.limitKind : limitKind, fetchedAt: max(fetchedAt, next.fetchedAt),
                                contextFetchedAt: newContext ? next.contextTimestamp : contextTimestamp,
                                outputFetchedAt: newOutput ? next.outputTimestamp : outputTimestamp)
    }
}

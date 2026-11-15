import Foundation

public enum KnowledgeEntityResolutionError: String, Error, Sendable {
    case invalidProfile = "invalid_resolution_profile"
    case duplicateEntity = "duplicate_resolution_entity"
    case missingEntity = "missing_resolution_entity"
    case kindMismatch = "resolution_kind_mismatch"
    case redirectCycle = "entity_redirect_cycle"
    case redirectLimit = "entity_redirect_limit"
}

/// Heuristics for REVIEW ordering, never calibrated identity probabilities.
/// The external specification's numeric profile was not available; this named
/// starting profile must be benchmarked before any automatic linking ships.
public struct KnowledgeEntityResolutionProfile: Codable, Equatable, Sendable {
    public let identifier: String
    public let exactNameWeight: Double
    public let aliasWeight: Double
    public let tokenWeight: Double
    public let minimumScore: Double
    public let maximumCandidates: Int

    public init(identifier: String, exactNameWeight: Double, aliasWeight: Double, tokenWeight: Double,
                minimumScore: Double, maximumCandidates: Int) throws {
        self.identifier = identifier
        self.exactNameWeight = exactNameWeight
        self.aliasWeight = aliasWeight
        self.tokenWeight = tokenWeight
        self.minimumScore = minimumScore
        self.maximumCandidates = maximumCandidates
        try validate()
    }

    public func validate() throws {
        let weights = [exactNameWeight, aliasWeight, tokenWeight]
        guard !identifier.isEmpty, identifier.utf8.count <= 80,
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              weights.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(weights.reduce(0, +) - 1) < 0.000_001,
              minimumScore.isFinite, (0...1).contains(minimumScore), (1...20).contains(maximumCandidates) else {
            throw KnowledgeEntityResolutionError.invalidProfile
        }
    }

    public static var experimental: Self {
        get throws {
            try Self(identifier: "experimental-v1", exactNameWeight: 0.60, aliasWeight: 0.15,
                     tokenWeight: 0.25, minimumScore: 0.15, maximumCandidates: 5)
        }
    }
}

public struct KnowledgeEntityResolutionValue: Sendable, Equatable {
    public let id: UUID
    public let kind: KnowledgeEntityKind
    public let name: String
    public let aliases: [String]
    public init(id: UUID, kind: KnowledgeEntityKind, name: String, aliases: [String] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.aliases = aliases
    }
}

public struct KnowledgeEntityResolutionMatch: Codable, Equatable, Sendable {
    public let entityID: UUID
    public let score: Double
    public let exactName: Bool
    public let aliasMatch: Bool
    public let tokenSimilarity: Double
    /// All candidates, including people, require an explicit host/user decision.
    public var requiresHumanReview: Bool { true }
}

public enum KnowledgeEntityResolver {
    public static func normalizedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func rank(_ query: KnowledgeEntityResolutionValue, candidates: [KnowledgeEntityResolutionValue],
                            profile: KnowledgeEntityResolutionProfile) throws -> [KnowledgeEntityResolutionMatch] {
        try profile.validate() // Synthesized Codable must not bypass validation.
        guard Set(candidates.map(\.id)).count == candidates.count else { throw KnowledgeEntityResolutionError.duplicateEntity }
        let name = normalizedName(query.name)
        guard !name.isEmpty else { return [] }
        let queryAliases = Set(query.aliases.map(normalizedName).filter { !$0.isEmpty })
        let queryTokens = tokens(name)
        let matches = candidates.compactMap { candidate -> KnowledgeEntityResolutionMatch? in
            guard candidate.id != query.id, candidate.kind == query.kind else { return nil }
            let candidateName = normalizedName(candidate.name)
            guard !candidateName.isEmpty else { return nil }
            let candidateAliases = Set(candidate.aliases.map(normalizedName).filter { !$0.isEmpty })
            let exact = candidateName == name
            let alias = !queryAliases.intersection(candidateAliases.union([candidateName])).isEmpty || candidateAliases.contains(name)
            let otherTokens = tokens(candidateName)
            let shared = queryTokens.intersection(otherTokens).count
            let union = queryTokens.union(otherTokens).count
            let similarity = union == 0 ? 0 : Double(shared) / Double(union)
            // A generic shared word alone is not a candidate signal.
            guard exact || alias || (shared >= 2 && similarity >= 0.5) else { return nil }
            let score = (exact ? profile.exactNameWeight : 0) + (alias ? profile.aliasWeight : 0) + similarity * profile.tokenWeight
            guard score >= profile.minimumScore else { return nil }
            return KnowledgeEntityResolutionMatch(entityID: candidate.id, score: score, exactName: exact,
                aliasMatch: alias, tokenSimilarity: similarity)
        }
        return Array(matches.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.entityID.uuidString < rhs.entityID.uuidString : lhs.score > rhs.score
        }.prefix(profile.maximumCandidates))
    }

    private static func tokens(_ name: String) -> Set<String> {
        Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
}

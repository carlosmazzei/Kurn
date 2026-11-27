//
//  KnowledgeInference+SameAs.swift
//  KurnCore
//
//  K7.4: virtual `same_as` candidates (CLAUDE.md "Knowledge derived edges (K7.4)"). Two
//  identities of one kind whose names or aliases look alike are offered as a candidate pair,
//  scored by the review-only entity resolver. A candidate is a suggestion to look at, never a
//  link: nothing is merged, nothing is stored, every pair still needs a human decision (the
//  review inbox), and the experimental score is not a calibrated probability. Pure and
//  deterministic.
//

import Foundation

extension KnowledgeInference {
    public struct SameAsCandidate: Equatable, Sendable {
        /// The two identities, the lower ID first (a candidate has no direction).
        public let firstID: UUID
        public let secondID: UUID
        public let score: Double
        public let exactName: Bool
        public let aliasMatch: Bool
        public let tokenSimilarity: Double
        /// Always `.inferred`.
        public var modality: KnowledgeModality { .inferred }
        /// Every candidate, people included, needs an explicit human decision.
        public var requiresHumanReview: Bool { true }
    }

    public struct SameAsResult: Equatable, Sendable {
        public let candidates: [SameAsCandidate]
        /// More identities than `maximumEntities`, or more eligible pairs than `maximumEdges`, were cut.
        public let isTruncated: Bool
    }

    /// The most identities compared (the wiki projection's own bound); the comparison is pairwise.
    public static let maximumEntities = 2_048
    /// Eligible pairs kept before choosing the best `maximumEdges`; past it the scan stops and the result
    /// is marked truncated (the best pairs among those seen are returned).
    public static let maximumPairsConsidered = maximumEdges * 64

    /// Candidate pairs among `entities`, best score first. A merged identity (a redirect to
    /// another) is skipped: its target stands for it. Pairs of different kinds never match.
    public static func deriveSameAsCandidates(
        from entities: [KnowledgeWikiSnapshot.Entity],
        profile: KnowledgeEntityResolutionProfile
    ) throws -> SameAsResult {
        try profile.validate()
        // A repeated ID with different data keeps the entry that sorts first by name and aliases, so the
        // input order never decides which one is compared.
        let live = entities.filter { $0.targetID == nil }.sorted { lhs, rhs in
            [lhs.id.uuidString, lhs.name, lhs.aliases.joined(separator: "\u{1}")]
                .lexicographicallyPrecedes([rhs.id.uuidString, rhs.name, rhs.aliases.joined(separator: "\u{1}")])
        }
        var unique: [KnowledgeWikiSnapshot.Entity] = []
        var seen = Set<UUID>()
        for entity in live where seen.insert(entity.id).inserted { unique.append(entity) }
        var truncated = unique.count > maximumEntities
        let compared = Array(unique.prefix(maximumEntities))
        let values = compared.map {
            KnowledgeEntityResolutionValue(id: $0.id, kind: $0.kind, name: $0.name, aliases: $0.aliases)
        }
        var pairs: [String: SameAsCandidate] = [:]
        scan: for query in values {
            for match in try KnowledgeEntityResolver.eligibleMatches(query, candidates: values, profile: profile) {
                if pairs.count >= maximumPairsConsidered { truncated = true; break scan }
                let ordered = [query.id, match.entityID].sorted { $0.uuidString < $1.uuidString }
                let key = ordered[0].uuidString + ordered[1].uuidString
                if pairs[key] == nil {
                    pairs[key] = SameAsCandidate(
                        firstID: ordered[0], secondID: ordered[1], score: match.score, exactName: match.exactName,
                        aliasMatch: match.aliasMatch, tokenSimilarity: match.tokenSimilarity)
                }
            }
        }
        let sorted = pairs.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return [lhs.firstID.uuidString, lhs.secondID.uuidString]
                .lexicographicallyPrecedes([rhs.firstID.uuidString, rhs.secondID.uuidString])
        }
        if sorted.count > maximumEdges { truncated = true }
        return SameAsResult(candidates: Array(sorted.prefix(maximumEdges)), isTruncated: truncated)
    }
}

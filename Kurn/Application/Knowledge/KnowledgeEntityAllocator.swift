import Foundation
import KurnCore
import SwiftData

/// Allocation still creates distinct identities. Lexical matches only create
/// review candidates; even an exact person name never reuses a canonical ID.
struct KnowledgeEntityAllocator {
    private let context: ModelContext
    private let snapshot: KnowledgeStoreSnapshot
    private let profile: KnowledgeEntityResolutionProfile
    private var candidates: [KnowledgeEntityResolutionValue]
    private var pairs: Set<String> = []
    private(set) var summary: KnowledgeEntityResolutionSummary

    init(snapshot: KnowledgeStoreSnapshot, context: ModelContext) throws {
        self.snapshot = snapshot
        self.context = context
        profile = try .experimental
        let pool = try KnowledgeEntityResolutionRows.pool(sources: [snapshot], in: context)
        candidates = try pool.values()
        summary = KnowledgeEntityResolutionSummary(profile: profile, poolTruncated: pool.truncated)
    }

    mutating func allocate(_ entities: [KnowledgeExtraction.Entity], at now: Date) throws -> [String: UUID] {
        var identities: [String: UUID] = [:]
        for entity in entities {
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = UUID()
            let value = KnowledgeEntityResolutionValue(id: id, kind: entity.kind, name: name, aliases: entity.aliases)
            context.insert(KnowledgeEntity(id: id, kind: entity.kind, canonicalName: name,
                normalizedName: KnowledgeEntityResolver.normalizedName(name), aliasesData: try KnowledgeStoreRows.authoritativeData(entity.aliases), createdAt: now))
            identities[entity.ref] = id
            let ranked = try KnowledgeEntityResolver.rank(value, candidates: candidates, profile: profile)
            for match in ranked { try suggest(sourceID: id, match: match, at: now) }
            if candidates.count < KnowledgeEntityResolutionRows.entityLimit { candidates.append(value) }
            else { summary.poolTruncated = true }
        }
        return identities
    }

    private mutating func suggest(sourceID: UUID, match: KnowledgeEntityResolutionMatch, at now: Date) throws {
        let key = [sourceID.uuidString, match.entityID.uuidString].sorted().joined(separator: ":")
        guard pairs.insert(key).inserted else { return }
        guard summary.reviewCount < KnowledgeEntityResolutionRows.reviewLimit else { summary.reviewLimitReached = true; return }
        let candidate = KnowledgeEntityReviewPayload.Candidate(scope: snapshot.scope,
            source: .init(meetingID: snapshot.meetingID, fingerprint: snapshot.transcriptFingerprint),
            policyRevisionKey: snapshot.policyRevisionKey, sourceID: sourceID, match: match, profile: profile)
        let payload = KnowledgeEntityReviewPayload(candidate: candidate)
        context.insert(KnowledgeReview(kind: .mergeCandidate, subjectIDsData: try KnowledgeStoreRows.authoritativeData([sourceID, match.entityID]),
            payloadData: try KnowledgeStoreRows.authoritativeData(payload), createdAt: now))
        summary.reviewCount += 1
    }
}

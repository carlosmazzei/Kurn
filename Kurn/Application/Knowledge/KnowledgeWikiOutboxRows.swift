import Foundation
import KurnCore
import SwiftData

enum KnowledgeWikiOutboxRows {
    /// A scoped publication cannot acknowledge another source/scope's work.
    /// Old-policy dependencies become obsolete only after newer compilations
    /// under the current policy cover their full source set. History is kept.
    static func acknowledgeCovered(sources: [KnowledgeStoreSnapshot], in context: ModelContext) throws {
        guard let source = sources.first else { return }
        let revisions = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.projectionPending }))
        for revision in revisions {
            if let jobID = revision.jobID {
                guard let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == jobID })).first,
                      job.kindRaw == KnowledgeJobKind.extraction.rawValue, job.stateRaw == KnowledgeJobState.succeeded.rawValue,
                      let identity = KnowledgeCompilationIdentity(idempotencyKey: job.idempotencyKey), identity.scope == source.scope,
                      let origin = sources.first(where: { $0.meetingID == identity.meetingID }) else { continue }
                _ = try KnowledgeEntityOriginRows.entityIDs(job, source: origin, historicalPolicies: true, in: context)
                if revision.policyRevisionKey == source.policyRevisionKey {
                    revision.projectionPending = false
                } else if try hasReplacement(after: revision.number, source: origin, in: context) {
                    revision.projectionPending = false
                }
            } else if try coversHumanRevision(revision, sources: sources, in: context) {
                revision.projectionPending = false
            }
        }
    }

    private static func hasReplacement(after number: Int, source: KnowledgeStoreSnapshot, in context: ModelContext) throws -> Bool {
        let key = source.policyRevisionKey
        let later = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.number > number && $0.policyRevisionKey == key }))
        for revision in later {
            guard let jobID = revision.jobID,
                  let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == jobID })).first,
                  job.kindRaw == KnowledgeJobKind.extraction.rawValue, job.stateRaw == KnowledgeJobState.succeeded.rawValue,
                  let identity = KnowledgeCompilationIdentity(idempotencyKey: job.idempotencyKey),
                  identity.scope == source.scope, identity.meetingID == source.meetingID,
                  identity.transcriptFingerprint == source.transcriptFingerprint else { continue }
            _ = try KnowledgeEntityOriginRows.entityIDs(job, source: source, historicalPolicies: false, in: context)
            return true
        }
        return false
    }

    private static func coversHumanRevision(_ revision: KnowledgeRevision, sources: [KnowledgeStoreSnapshot], in context: ModelContext) throws -> Bool {
        let kind = KnowledgeReviewItemKind.mergeCandidate.rawValue
        let resolved = KnowledgeReviewItemState.resolved.rawValue
        let reviews = try context.fetch(FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.kindRaw == kind && $0.stateRaw == resolved }))
        for row in reviews {
            let payload = try KnowledgeEntityResolutionRows.reviewPayload(row)
            guard let merge = payload.merge, merge.applied.revisionID == revision.id || merge.undone?.revisionID == revision.id else { continue }
            _ = try KnowledgeEntityMergeRows.checkedAudit(row, payload: payload, in: context)
            guard merge.scope == sources.first?.scope, Set(merge.sources.map(\.meetingID)).isSubset(of: Set(sources.map(\.meetingID))) else { return false }
            if revision.policyRevisionKey == sources.first?.policyRevisionKey { return true }
            for id in merge.sources.map(\.meetingID) {
                guard let source = sources.first(where: { $0.meetingID == id }),
                      try hasReplacement(after: revision.number, source: source, in: context) else { return false }
            }
            return true
        }
        return false
    }
}

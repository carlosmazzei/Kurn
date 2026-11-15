import Foundation
import KurnCore
import SwiftData

/// Redirect edits, audit and the projection outbox share one transaction.
/// Assertion, relation, event and evidence identities are never rewritten.
enum KnowledgeEntityMergeRows {
    static func apply(_ request: KnowledgeEntityMergeRequest, auth: KnowledgeEntityResolutionAuthorization,
                      container: ModelContainer, beforeSave: @Sendable () throws -> Void) throws -> KnowledgeEntityMergeReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var result: KnowledgeEntityMergeReceipt?
            try context.transaction {
                let sources = try KnowledgeEntityResolutionRows.refreshed(request.snapshot, auth: auth, in: context)
                let pool = try KnowledgeEntityResolutionRows.pool(sources: sources, in: context)
                guard pool.rows[request.sourceID] != nil, pool.rows[request.targetID] != nil else { throw KnowledgeEntityStoreError.scopeDenied }
                let operationID = request.operationID
                if let existing = try context.fetch(FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.id == operationID })).first {
                    let payload = try KnowledgeEntityResolutionRows.reviewPayload(existing)
                    guard let audit = try checkedAudit(existing, payload: payload, in: context), audit.scope == request.snapshot.scope,
                          audit.policyRevisionKey == request.snapshot.policyRevisionKey, audit.sources == request.snapshot.sources,
                          audit.applied.sourceID == request.sourceID, audit.requestedTargetID == request.targetID,
                          audit.candidateReviewID == request.candidateReviewID else { throw KnowledgeEntityStoreError.invalidReview }
                    guard audit.undone == nil else { throw KnowledgeEntityStoreError.operationUndone }
                    guard pool.rows[audit.applied.sourceID]?.mergedIntoID == audit.applied.targetID,
                          pool.rows[audit.applied.targetID] != nil, pool.rows[audit.requestedTargetID] != nil else { throw KnowledgeEntityStoreError.mergeChanged }
                    result = audit.applied
                    return
                }
                guard try KnowledgeStoreRows.latestRevision(in: context) == request.snapshot.revision else { throw KnowledgeEntityStoreError.staleSnapshot }
                guard let source = pool.rows[request.sourceID], let selectedTarget = pool.rows[request.targetID] else { throw KnowledgeEntityStoreError.scopeDenied }
                try requireVisible(source)
                try requireVisible(selectedTarget)
                guard source.mergedIntoID == nil else { throw KnowledgeEntityStoreError.alreadyMerged }
                let targetID = try KnowledgeEntityRedirectGraph.resolve(request.targetID, nodes: pool.redirects())
                guard source.id != targetID else { throw KnowledgeEntityResolutionError.redirectCycle }
                guard let target = pool.rows[targetID], source.kindRaw == target.kindRaw else { throw KnowledgeEntityResolutionError.kindMismatch }
                try requireVisible(target)
                let members = try incomingGroup(source.id, allowed: Set(pool.rows.keys), in: context)
                var graph = try pool.redirects()
                guard let kind = KnowledgeEntityKind(rawValue: source.kindRaw) else { throw KnowledgeEntityStoreError.unreadablePayload }
                graph[source.id] = KnowledgeEntityRedirect(id: source.id, kind: kind, targetID: targetID)
                for member in members { _ = try KnowledgeEntityRedirectGraph.resolve(member, nodes: graph) }
                let candidate = try candidateReview(request, in: context)
                let now = Date()
                let receipt = try revision(operationID: operationID, sourceID: source.id, targetID: targetID,
                    snapshot: request.snapshot, isUndo: false, in: context)
                source.mergedIntoID = targetID
                source.updatedAt = now
                let audit = KnowledgeEntityReviewPayload.Merge(scope: request.snapshot.scope, sources: request.snapshot.sources,
                    policyRevisionKey: request.snapshot.policyRevisionKey, requestedTargetID: request.targetID,
                    candidateReviewID: request.candidateReviewID, applied: receipt)
                let row = KnowledgeReview(id: operationID, kind: .mergeCandidate,
                    subjectIDsData: try KnowledgeStoreRows.authoritativeData([source.id, targetID]),
                    payloadData: try KnowledgeStoreRows.authoritativeData(KnowledgeEntityReviewPayload(merge: audit)), createdAt: now)
                row.stateRaw = KnowledgeReviewItemState.resolved.rawValue
                row.resolvedAt = now
                context.insert(row)
                if let candidate {
                    var payload = try KnowledgeEntityResolutionRows.reviewPayload(candidate)
                    payload.resolvedByOperationID = operationID
                    candidate.payloadData = try KnowledgeStoreRows.authoritativeData(payload)
                    candidate.stateRaw = KnowledgeReviewItemState.resolved.rawValue
                    candidate.resolvedAt = now
                }
                try Task.checkCancellation()
                try beforeSave()
                try context.save()
                result = receipt
            }
            guard let result else { throw KnowledgeEntityStoreError.invalidReview }
            return result
        } catch { context.rollback(); throw error }
    }

    static func undo(operationID: UUID, snapshot: KnowledgeEntityResolutionSnapshot, auth: KnowledgeEntityResolutionAuthorization,
                     container: ModelContainer, beforeSave: @Sendable () throws -> Void) throws -> KnowledgeEntityMergeReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var result: KnowledgeEntityMergeReceipt?
            try context.transaction {
                let sources = try KnowledgeEntityResolutionRows.refreshed(snapshot, auth: auth, in: context)
                let pool = try KnowledgeEntityResolutionRows.pool(sources: sources, includeHistoricalPolicies: true, in: context)
                guard let row = try context.fetch(FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.id == operationID })).first else {
                    throw KnowledgeEntityStoreError.invalidReview
                }
                var payload = try KnowledgeEntityResolutionRows.reviewPayload(row)
                guard var audit = try checkedAudit(row, payload: payload, in: context), audit.scope == snapshot.scope,
                      Set(audit.sources.map(\.meetingID)).isSubset(of: Set(snapshot.sources.map(\.meetingID))) else {
                    throw KnowledgeEntityStoreError.scopeDenied
                }
                guard let source = pool.rows[audit.applied.sourceID], pool.rows[audit.applied.targetID] != nil else { throw KnowledgeEntityStoreError.scopeDenied }
                if let undone = audit.undone { result = undone; return }
                guard try KnowledgeStoreRows.latestRevision(in: context) == snapshot.revision else { throw KnowledgeEntityStoreError.staleSnapshot }
                guard source.mergedIntoID == audit.applied.targetID else { throw KnowledgeEntityStoreError.mergeChanged }
                _ = try incomingGroup(source.id, allowed: Set(pool.rows.keys), in: context)
                let receipt = try revision(operationID: operationID, sourceID: source.id, targetID: audit.applied.targetID,
                    snapshot: snapshot, isUndo: true, in: context)
                source.mergedIntoID = nil
                source.updatedAt = Date()
                audit.undone = receipt
                audit.undoPolicyRevisionKey = snapshot.policyRevisionKey
                payload.merge = audit
                row.payloadData = try KnowledgeStoreRows.authoritativeData(payload)
                if let candidateID = audit.candidateReviewID,
                   let candidate = try context.fetch(FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.id == candidateID })).first {
                    var candidatePayload = try KnowledgeEntityResolutionRows.reviewPayload(candidate)
                    guard candidatePayload.resolvedByOperationID == operationID, candidate.stateRaw == "resolved" else {
                        throw KnowledgeEntityStoreError.mergeChanged
                    }
                    candidatePayload.resolvedByOperationID = nil
                    candidate.payloadData = try KnowledgeStoreRows.authoritativeData(candidatePayload)
                    candidate.stateRaw = KnowledgeReviewItemState.open.rawValue
                    candidate.resolvedAt = nil
                }
                try Task.checkCancellation()
                try beforeSave()
                try context.save()
                result = receipt
            }
            guard let result else { throw KnowledgeEntityStoreError.invalidReview }
            return result
        } catch { context.rollback(); throw error }
    }

    private static func requireVisible(_ entity: KnowledgeEntity) throws {
        guard let state = KnowledgeReviewState(rawValue: entity.reviewStateRaw), state.isVisible else { throw KnowledgeEntityStoreError.inactiveEntity }
    }

    /// Merging or splitting a root affects every inbound redirect. An excluded
    /// descendant must not have its identity changed by a narrower selection.
    private static func incomingGroup(_ root: UUID, allowed: Set<UUID>, in context: ModelContext) throws -> Set<UUID> {
        var pending = [root]
        var seen: Set<UUID> = []
        while let id = pending.popLast() {
            guard seen.insert(id).inserted else { throw KnowledgeEntityResolutionError.redirectCycle }
            guard seen.count <= KnowledgeEntityResolutionRows.entityLimit else { throw KnowledgeEntityResolutionError.redirectLimit }
            let children = try context.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { $0.mergedIntoID == id }))
            for child in children {
                guard allowed.contains(child.id) else { throw KnowledgeEntityStoreError.scopeDenied }
                pending.append(child.id)
            }
        }
        return seen
    }

    private static func candidateReview(_ request: KnowledgeEntityMergeRequest, in context: ModelContext) throws -> KnowledgeReview? {
        guard let id = request.candidateReviewID else { return nil }
        guard id != request.operationID,
              let row = try context.fetch(FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.id == id })).first,
              row.stateRaw == KnowledgeReviewItemState.open.rawValue else { throw KnowledgeEntityStoreError.invalidReview }
        let payload = try KnowledgeEntityResolutionRows.reviewPayload(row)
        guard let candidate = payload.candidate, candidate.scope == request.snapshot.scope,
              candidate.policyRevisionKey == request.snapshot.policyRevisionKey,
              request.snapshot.sources.contains(candidate.source), payload.resolvedByOperationID == nil,
              Set([candidate.sourceID, candidate.match.entityID]) == Set([request.sourceID, request.targetID]) else {
            throw KnowledgeEntityStoreError.invalidReview
        }
        guard candidate.match.score.isFinite, (0...1).contains(candidate.match.score),
              candidate.match.tokenSimilarity.isFinite, (0...1).contains(candidate.match.tokenSimilarity) else { throw KnowledgeEntityStoreError.invalidReview }
        try candidate.profile.validate()
        return row
    }

    // swiftlint:disable:next function_parameter_count
    private static func revision(operationID: UUID, sourceID: UUID, targetID: UUID,
                                 snapshot: KnowledgeEntityResolutionSnapshot, isUndo: Bool, in context: ModelContext) throws -> KnowledgeEntityMergeReceipt {
        let number = try KnowledgeStoreRows.latestRevision(in: context) + 1
        let revision = KnowledgeRevision(number: number, policyRevisionKey: snapshot.policyRevisionKey, assertionCount: 0)
        context.insert(revision)
        return KnowledgeEntityMergeReceipt(operationID: operationID, sourceID: sourceID, targetID: targetID,
            revisionID: revision.id, revision: number, isUndo: isUndo)
    }
}

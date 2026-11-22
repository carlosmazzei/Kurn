import Foundation
import KurnCore
import SwiftData

enum KnowledgeReviewRows {
    static func read(meetingIDs: Set<UUID>, auth: KnowledgeSourceAuthorization, in context: ModelContext) throws -> KnowledgeReviewRead {
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: meetingIDs, scope: "workspace", auth: auth, operation: .semanticLint, in: context)
        let pool = try KnowledgeEntityResolutionRows.pool(sources: sources, includeHistoricalPolicies: true, in: context)
        let tokens = KnowledgeEntityResolutionRows.tokens(sources)
        let policy = KnowledgePolicyEvaluator.revisionKey(auth.policies)
        let snapshot = KnowledgeEntityMutationSnapshot(scope: "workspace", revision: try KnowledgeStoreRows.latestRevision(in: context),
            policyRevisionKey: policy, sources: tokens)
        let kind = KnowledgeReviewItemKind.mergeCandidate.rawValue
        var descriptor = FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\KnowledgeReview.createdAt, order: .reverse), SortDescriptor(\KnowledgeReview.id)])
        descriptor.fetchLimit = 256
        var candidates: [KnowledgeReviewRead.Candidate] = []
        var dismissed: [KnowledgeReviewRead.Candidate] = []
        var merges: [KnowledgeReviewRead.Merge] = []
        let allowedIDs = Set(pool.rows.keys)
        var scanned = 0
        var truncated = pool.truncated
        while scanned < 16_384 {
            try Task.checkCancellation()
            descriptor.fetchOffset = scanned
            let rows = try context.fetch(descriptor)
            scanned += rows.count
            for row in rows {
                try Task.checkCancellation()
                guard row.kindRaw == KnowledgeReviewItemKind.mergeCandidate.rawValue,
                      let subjects = try? KnowledgeEntityResolutionRows.decode([UUID].self, row.subjectIDsData),
                      subjects.count == 2, Set(subjects).count == 2, Set(subjects).isSubset(of: allowedIDs) else { continue }
                let payload = try KnowledgeEntityResolutionRows.reviewPayload(row)
                if let candidate = payload.candidate {
                    guard candidate.scope == snapshot.scope, candidate.policyRevisionKey == policy,
                          tokens.contains(candidate.source), payload.resolvedByOperationID == nil,
                          Set(subjects) == Set([candidate.sourceID, candidate.match.entityID]),
                          let state = KnowledgeReviewItemState(rawValue: row.stateRaw), [.open, .dismissed].contains(state) else { continue }
                    try candidate.profile.validate()
                    guard candidate.match.score.isFinite, (0...1).contains(candidate.match.score),
                          candidate.match.tokenSimilarity.isFinite, (0...1).contains(candidate.match.tokenSimilarity),
                          let source = try value(candidate.sourceID, pool: pool), let target = try value(candidate.match.entityID, pool: pool),
                          source.kind == target.kind else { throw KnowledgeEntityStoreError.invalidReview }
                    guard pool.rows[source.id]?.mergedIntoID == nil, pool.rows[target.id]?.mergedIntoID == nil else { continue }
                    do { _ = try KnowledgeEntityOriginRows.prove(Set(subjects), sources: sources, in: context) }
                    catch KnowledgeEntityStoreError.scopeDenied { continue }
                    let item = KnowledgeReviewRead.Candidate(id: row.id, source: source, target: target, isDismissed: state == .dismissed)
                    if item.isDismissed {
                        if dismissed.count < 128 { dismissed.append(item) } else { truncated = true }
                    } else if candidates.count < 128 { candidates.append(item) }
                    else { truncated = true }
                } else if let audit = payload.merge {
                    guard audit.scope == snapshot.scope, Set(audit.origins.map(\.meetingID)).isSubset(of: meetingIDs) else { continue }
                    _ = try KnowledgeEntityMergeRows.checkedAudit(row, payload: payload, in: context)
                    try KnowledgeEntityOriginRows.verify(audit.origins, sources: sources, in: context)
                    guard let source = try value(audit.applied.sourceID, pool: pool), let target = try value(audit.applied.targetID, pool: pool) else { continue }
                    if merges.count < 128 {
                        merges.append(.init(receipt: audit.applied, sourceName: source.name, targetName: target.name, isUndone: audit.undone != nil))
                    } else { truncated = true }
                }
            }
            if rows.count < 256 { break }
            if scanned >= 16_384 { truncated = true }
        }
        let warnings = try warnings(sources: sources, in: context)
        let canMutate = (try? auth.authorize(classifications: sources.map(\.contextClassification), operation: .extraction)) != nil
        return KnowledgeReviewRead(snapshot: snapshot, candidates: candidates + dismissed, merges: merges,
            warnings: warnings.items, evidenceUnavailable: warnings.unavailable,
            isTruncated: truncated, allowsMutation: canMutate)
    }

    private static func value(_ id: UUID, pool: KnowledgeEntityResolutionRows.Pool) throws -> KnowledgeEntityResolutionValue? {
        guard let row = pool.rows[id], let kind = KnowledgeEntityKind(rawValue: row.kindRaw),
              let state = KnowledgeReviewState(rawValue: row.reviewStateRaw) else { throw KnowledgeEntityStoreError.invalidReview }
        guard state.isVisible else { return nil }
        return KnowledgeEntityResolutionValue(id: id, kind: kind, name: row.canonicalName,
            aliases: try KnowledgeEntityResolutionRows.decode([String].self, row.aliasesData))
    }

    private static func warnings(sources: [KnowledgeStoreSnapshot], in context: ModelContext) throws -> (items: [KnowledgeReviewRead.Warning], unavailable: Bool) {
        do {
            var maintenance = KnowledgeMaintenanceInput(revision: try KnowledgeStoreRows.latestRevision(in: context))
            for source in sources { _ = try KnowledgeMaintenanceRows.compilation(source: source, input: &maintenance, in: context) }
            let needsInspection = !maintenance.isComplete || maintenance.coverage.contains { $0.state != .current }
            let wiki = try KnowledgeWikiSourceRows.snapshot(sources: sources, in: context).wiki
            let pages = try KnowledgeWikiProjector.project(wiki)
            let entries = pages.flatMap { $0.sections.flatMap(\.entries) }
            let byID = Dictionary(entries.map { ($0.fact.id, $0) }, uniquingKeysWith: { first, _ in first })
            return (try KnowledgeReviewProjection.hints(pages: pages).map { hint in
                KnowledgeReviewRead.Warning(id: hint.id, kind: hint.kind, entries: hint.assertionIDs.compactMap { byID[$0] })
            }, needsInspection)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if KnowledgeMaintenanceRows.isFuture(error) || (error as? KnowledgeMaintenanceError) == .limitExceeded { throw error }
            // Never present a broken citation's raw payload as evidence.
            return ([], true)
        }
    }
}

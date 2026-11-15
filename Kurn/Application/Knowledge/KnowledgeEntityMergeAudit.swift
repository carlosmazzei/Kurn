import Foundation
import KurnCore
import SwiftData

extension KnowledgeEntityMergeRows {
    static func checkedAudit(_ row: KnowledgeReview, payload: KnowledgeEntityReviewPayload,
                             in context: ModelContext) throws -> KnowledgeEntityReviewPayload.Merge? {
        guard let audit = payload.merge, payload.resolvedByOperationID == nil,
              row.stateRaw == KnowledgeReviewItemState.resolved.rawValue else { throw KnowledgeEntityStoreError.invalidReview }
        let applied = audit.applied
        let ids = try KnowledgeEntityResolutionRows.decode([UUID].self, row.subjectIDsData)
        guard applied.operationID == row.id, !applied.isUndo, applied.sourceID != applied.targetID,
              ids.count == 2, Set(ids) == Set([applied.sourceID, applied.targetID]),
              !audit.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !audit.sources.isEmpty,
              Set(audit.sources.map(\.meetingID)).count == audit.sources.count else { throw KnowledgeEntityStoreError.invalidReview }
        let bound = Set(audit.origins.map(\.entityID))
        guard bound.count == audit.origins.count, bound.count <= 1_088, bound.isSuperset(of: [applied.sourceID, applied.targetID, audit.requestedTargetID]),
              Set(audit.origins.map(\.meetingID)).isSubset(of: Set(audit.sources.map(\.meetingID))) else {
            throw KnowledgeEntityStoreError.invalidReview
        }
        try checkRevision(applied, policyKey: audit.policyRevisionKey, in: context)
        if let undone = audit.undone {
            guard undone.operationID == applied.operationID, undone.sourceID == applied.sourceID, undone.targetID == applied.targetID,
                  undone.isUndo, undone.revision > applied.revision, let policyKey = audit.undoPolicyRevisionKey else {
                throw KnowledgeEntityStoreError.invalidReview
            }
            try checkRevision(undone, policyKey: policyKey, in: context)
        } else if audit.undoPolicyRevisionKey != nil { throw KnowledgeEntityStoreError.invalidReview }
        return audit
    }

    private static func checkRevision(_ receipt: KnowledgeEntityMergeReceipt, policyKey: String, in context: ModelContext) throws {
        let id = receipt.revisionID
        guard let row = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.id == id })).first,
              row.number == receipt.revision, row.policyRevisionKey == policyKey, row.jobID == nil, row.assertionCount == 0 else {
            throw KnowledgeEntityStoreError.invalidReview
        }
    }
}

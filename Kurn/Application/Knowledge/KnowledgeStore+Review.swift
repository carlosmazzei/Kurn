import Foundation
import KurnCore
import SwiftData

extension KnowledgeStore {
    func reviewInbox(meetingIDs: Set<UUID>, authorization: @Sendable () async -> KnowledgeSourceAuthorization) async throws -> KnowledgeReviewRead {
        let auth = await authorization()
        try Task.checkCancellation()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return try KnowledgeReviewRows.read(meetingIDs: meetingIDs, auth: auth, in: context)
    }

    func reviewDecision(_ command: KnowledgeReviewCommand, snapshot: KnowledgeEntityMutationSnapshot,
                        authorization: @Sendable () async -> KnowledgeSourceAuthorization,
                        beforeSave: @Sendable () throws -> Void = {}) async throws {
        let auth = await authorization()
        try Task.checkCancellation()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let fresh = try KnowledgeReviewRows.read(meetingIDs: Set(snapshot.sources.map(\.meetingID)), auth: auth, in: context)
            guard fresh.snapshot == snapshot, fresh.allowsMutation, snapshot.revision < Int.max else { throw KnowledgeEntityStoreError.staleSnapshot }
            let identityAuth = KnowledgeEntityResolutionAuthorization(extraction: auth.extraction, meetingIDs: auth.meetingIDs)
            switch command {
            case let .merge(id):
                guard let candidate = fresh.candidates.first(where: { $0.id == id && !$0.isDismissed }) else { throw KnowledgeEntityStoreError.invalidReview }
                _ = try KnowledgeEntityMergeRows.apply(.init(operationID: UUID(), sourceID: candidate.source.id,
                    targetID: candidate.target.id, snapshot: snapshot, candidateReviewID: id),
                    auth: identityAuth, container: modelContainer, beforeSave: beforeSave)
            case let .undo(id):
                guard fresh.merges.contains(where: { $0.id == id && !$0.isUndone }) else { throw KnowledgeEntityStoreError.invalidReview }
                _ = try KnowledgeEntityMergeRows.undo(operationID: id, snapshot: snapshot, auth: identityAuth,
                    container: modelContainer, beforeSave: beforeSave)
            case let .dismiss(id), let .reopen(id):
                try saveReviewState(id: id, dismissed: command == .dismiss(id), snapshot: snapshot, auth: auth, beforeSave: beforeSave)
            }
        } catch {
            context.rollback()
            ReliabilityLog.record(ReliabilityEvent(operationID: OperationID(), operation: "knowledge_review", stage: "decision",
                outcome: error is CancellationError ? .cancelled : .failed, code: (error as? KnowledgeEntityStoreError)?.rawValue ?? "review_decision_failed"))
            throw error
        }
    }

    private func saveReviewState(id: UUID, dismissed: Bool, snapshot: KnowledgeEntityMutationSnapshot,
                                 auth: KnowledgeSourceAuthorization, beforeSave: @Sendable () throws -> Void) throws {
        // Revalidate inside the write transaction using a fresh context, rather
        // than saving objects materialized by an earlier inbox read.
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            try context.transaction {
                let current = try KnowledgeReviewRows.read(meetingIDs: Set(snapshot.sources.map(\.meetingID)), auth: auth, in: context)
                guard current.snapshot == snapshot, current.allowsMutation else { throw KnowledgeEntityStoreError.staleSnapshot }
                guard current.candidates.contains(where: { $0.id == id && $0.isDismissed != dismissed }),
                      let row = try context.fetch(FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.id == id })).first else {
                    throw KnowledgeEntityStoreError.invalidReview
                }
                row.stateRaw = dismissed ? KnowledgeReviewItemState.dismissed.rawValue : KnowledgeReviewItemState.open.rawValue
                row.resolvedAt = dismissed ? Date() : nil
                // Review metadata changes neither canonical page inputs nor
                // their revision/outbox. The transaction still requires the
                // current canonical proof and this review's expected state.
                try Task.checkCancellation()
                try beforeSave()
                try context.save()
            }
        } catch { context.rollback(); throw error }
    }
}

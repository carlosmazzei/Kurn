import Foundation
import KurnCore
import SwiftData

/// The host owns ONE writer per container (K1.6). Actor isolation serializes
/// commits and projection acknowledgements; no model and no context escapes.
/// Fresh contexts avoid cached transcript bytes surviving between commits.
@ModelActor
actor KnowledgeStore {
    func snapshot(
        meetingID: UUID, scope: String, provider: AIProvider,
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization
    ) async throws -> KnowledgeStoreSnapshot {
        let auth = await authorization()
        try Task.checkCancellation()
        guard auth.decision(for: provider).isAllowed else { throw KnowledgeStoreError.policyDenied }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let source = try KnowledgeStoreRows.readSnapshot(meetingID: meetingID, scope: scope, auth: auth, in: context)
        try KnowledgeStoreRows.authorize(auth, source: source, provider: provider)
        return source
    }

    func commit(
        _ request: KnowledgeCommitRequest,
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization,
        beforeSave: @Sendable () throws -> Void = {}
    ) async throws -> KnowledgeCommitReceipt {
        // Await the live host policy immediately before entering the synchronous
        // transaction. There is no suspension between source/revision checks,
        // canonical writes, the job transition, the outbox and the one save.
        let auth = await authorization()
        try Task.checkCancellation()
        guard auth.decision(for: request.provider).isAllowed else { throw KnowledgeStoreError.policyDenied }
        return try KnowledgeStoreRows.commit(request, auth: auth, container: modelContainer, beforeSave: beforeSave)
    }

    func compilationReplay(_ work: KnowledgeQueuedWork,
                           authorization: @Sendable () async -> KnowledgeExtractionAuthorization) async throws -> KnowledgeCommitReceipt? {
        let auth = await authorization()
        try Task.checkCancellation()
        guard auth.decision(for: work.provider).isAllowed else { throw KnowledgeStoreError.policyDenied }
        return try KnowledgeStoreRows.replay(work, auth: auth, container: modelContainer)
    }

    func pendingProjection() throws -> KnowledgeCommitReceipt? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.projectionPending },
            sortBy: [SortDescriptor(\KnowledgeRevision.number, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map { KnowledgeStoreRows.receipt($0, replay: false) }
    }

}

import Foundation
import KurnCore
import SwiftData

extension KnowledgeStore {
    func entityResolutionSnapshot(meetingIDs: Set<UUID>, scope: String,
                                  authorization: @Sendable () async -> KnowledgeEntityResolutionAuthorization) async throws -> KnowledgeEntityResolutionSnapshot {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeEntityResolutionRows.read(meetingIDs: meetingIDs, scope: scope, auth: auth, container: modelContainer)
    }

    /// Host-only mutation seam for an explicit human decision. Never registered
    /// as a model tool, and never invoked by the extraction model's JSON.
    func mergeEntities(_ request: KnowledgeEntityMergeRequest,
                       authorization: @Sendable () async -> KnowledgeEntityResolutionAuthorization,
                       beforeSave: @Sendable () throws -> Void = {}) async throws -> KnowledgeEntityMergeReceipt {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeEntityMergeRows.apply(request, auth: auth, container: modelContainer, beforeSave: beforeSave)
    }

    func undoEntityMerge(operationID: UUID, snapshot: KnowledgeEntityResolutionSnapshot,
                         authorization: @Sendable () async -> KnowledgeEntityResolutionAuthorization,
                         beforeSave: @Sendable () throws -> Void = {}) async throws -> KnowledgeEntityMergeReceipt {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeEntityMergeRows.undo(operationID: operationID, snapshot: snapshot, auth: auth, container: modelContainer, beforeSave: beforeSave)
    }
}

extension KnowledgeEntityResolutionRows {
    static func read(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeEntityResolutionAuthorization,
                     container: ModelContainer) throws -> KnowledgeEntityResolutionSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sources = try sources(meetingIDs: meetingIDs, scope: scope, auth: auth, in: context)
        return try snapshot(sources: sources, pool: pool(sources: sources, in: context), in: context)
    }
}

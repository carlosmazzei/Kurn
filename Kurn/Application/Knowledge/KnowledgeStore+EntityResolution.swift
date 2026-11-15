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

    func entityMutationSnapshot(meetingIDs: Set<UUID>, scope: String,
                                authorization: @Sendable () async -> KnowledgeEntityResolutionAuthorization) async throws -> KnowledgeEntityMutationSnapshot {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeEntityResolutionRows.readMutation(meetingIDs: meetingIDs, scope: scope, auth: auth, container: modelContainer)
    }

    /// Host-only mutation seam for an explicit human decision. Never registered
    /// as a model tool, and never invoked by the extraction model's JSON.
    func mergeEntities(_ request: KnowledgeEntityMergeRequest,
                       authorization: @Sendable () async -> KnowledgeEntityResolutionAuthorization,
                       beforeSave: @Sendable () throws -> Void = {}) async throws -> KnowledgeEntityMergeReceipt {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeEntityMutationDiagnostics.run(operationID: request.operationID, stage: "merge") {
            try KnowledgeEntityMergeRows.apply(request, auth: auth, container: modelContainer, beforeSave: beforeSave)
        }
    }

    func undoEntityMerge(operationID: UUID, snapshot: KnowledgeEntityMutationSnapshot,
                         authorization: @Sendable () async -> KnowledgeEntityResolutionAuthorization,
                         beforeSave: @Sendable () throws -> Void = {}) async throws -> KnowledgeEntityMergeReceipt {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeEntityMutationDiagnostics.run(operationID: operationID, stage: "undo") {
            try KnowledgeEntityMergeRows.undo(operationID: operationID, snapshot: snapshot, auth: auth, container: modelContainer, beforeSave: beforeSave)
        }
    }
    func undoEntityMerge(operationID: UUID, snapshot: KnowledgeEntityResolutionSnapshot,
                         authorization: @Sendable () async -> KnowledgeEntityResolutionAuthorization,
                         beforeSave: @Sendable () throws -> Void = {}) async throws -> KnowledgeEntityMergeReceipt {
        try await undoEntityMerge(operationID: operationID, snapshot: snapshot.mutation, authorization: authorization, beforeSave: beforeSave)
    }

}

extension KnowledgeEntityResolutionRows {
    static func readMutation(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeEntityResolutionAuthorization,
                             container: ModelContainer) throws -> KnowledgeEntityMutationSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let current = try sources(meetingIDs: meetingIDs, scope: scope, auth: auth, in: context)
        guard let first = current.first else { throw KnowledgeEntityStoreError.scopeDenied }
        return KnowledgeEntityMutationSnapshot(scope: scope, revision: try KnowledgeStoreRows.latestRevision(in: context),
            policyRevisionKey: first.policyRevisionKey, sources: tokens(current))
    }

    static func read(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeEntityResolutionAuthorization,
                     container: ModelContainer) throws -> KnowledgeEntityResolutionSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sources = try sources(meetingIDs: meetingIDs, scope: scope, auth: auth, in: context)
        return try snapshot(sources: sources, pool: pool(sources: sources, in: context), in: context)
    }
}

/// Mutation failures need durable, content-free diagnostics even before the
/// review UI exists. Expected scope/staleness and graph refusals are not faults.
private enum KnowledgeEntityMutationDiagnostics {
    static func run(operationID: UUID, stage: String, body: () throws -> KnowledgeEntityMergeReceipt) throws -> KnowledgeEntityMergeReceipt {
        let id = OperationID(String(operationID.uuidString.prefix(8)))
        let started = Date()
        do {
            let result = try body()
            ReliabilityLog.record(ReliabilityEvent(operationID: id, operation: "knowledge_entity_identity", stage: stage,
                outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(started)))
            return result
        } catch is CancellationError {
            ReliabilityLog.record(ReliabilityEvent(operationID: id, operation: "knowledge_entity_identity", stage: stage,
                outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(started), code: "interrupted"))
            throw CancellationError()
        } catch let error as KnowledgeEntityStoreError where [.scopeDenied, .staleSnapshot, .alreadyMerged, .operationUndone, .mergeChanged].contains(error) {
            throw error
        } catch let error as KnowledgeEntityResolutionError {
            throw error
        } catch {
            let code = (error as? KnowledgeEntityStoreError)?.rawValue ?? (error as? KnowledgeStoreError)?.rawValue
                ?? (error as? AppError)?.logCode ?? "identity_mutation_failed"
            ReliabilityLog.record(ReliabilityEvent(operationID: id, operation: "knowledge_entity_identity", stage: stage,
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(started), code: code))
            throw error
        }
    }
}

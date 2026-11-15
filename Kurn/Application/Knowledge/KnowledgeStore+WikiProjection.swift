import Foundation
import KurnCore
import SwiftData

extension KnowledgeStore {
    func wikiProjectionSnapshot(meetingIDs: Set<UUID>, scope: String,
                               authorization: @Sendable () async -> KnowledgeWikiAuthorization) async throws -> KnowledgeWikiProjectionSnapshot {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeWikiProjectionReader.snapshot(meetingIDs: meetingIDs, scope: scope, auth: auth, container: modelContainer)
    }

    /// The caller may supply optional local narrative output. This API performs
    /// no model call and cannot authorize egress; publication revalidates every
    /// input against the live canonical/source/policy snapshot without awaits.
    func publishWikiProjection(_ snapshot: KnowledgeWikiProjectionSnapshot, narratives: [KnowledgeWikiNarrative] = [],
                               authorization: @Sendable () async -> KnowledgeWikiAuthorization,
                               beforeSave: @Sendable () throws -> Void = {}) async throws -> KnowledgeWikiProjection {
        let auth = await authorization()
        try Task.checkCancellation()
        let started = Date()
        let operationID = OperationID()
        do {
            let result = try KnowledgeWikiProjectionRows.publish(snapshot, narratives: narratives, auth: auth,
                container: modelContainer, beforeSave: beforeSave)
            ReliabilityLog.record(ReliabilityEvent(operationID: operationID, operation: "knowledge_wiki_projection", stage: "publish",
                outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(started)))
            return result
        } catch is CancellationError {
            ReliabilityLog.record(ReliabilityEvent(operationID: operationID, operation: "knowledge_wiki_projection", stage: "publish",
                outcome: .cancelled, code: "interrupted"))
            throw CancellationError()
        } catch {
            let code = (error as? KnowledgeWikiStoreError)?.rawValue ?? (error as? KnowledgeWikiProjectionError)?.rawValue
                ?? (error as? KnowledgeStoreError)?.rawValue ?? "wiki_publication_failed"
            ReliabilityLog.record(ReliabilityEvent(operationID: operationID, operation: "knowledge_wiki_projection", stage: "publish",
                outcome: .failed, code: code))
            throw error
        }
    }

    func wikiProjection(meetingIDs: Set<UUID>, scope: String,
                        authorization: @Sendable () async -> KnowledgeWikiAuthorization) async throws -> KnowledgeWikiProjection? {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeWikiProjectionRows.read(meetingIDs: meetingIDs, scope: scope, auth: auth, container: modelContainer)
    }
}

private enum KnowledgeWikiProjectionReader {
    static func snapshot(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeWikiAuthorization,
                         container: ModelContainer) throws -> KnowledgeWikiProjectionSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: meetingIDs, scope: scope, auth: auth, in: context)
        return try KnowledgeWikiSourceRows.snapshot(sources: sources, in: context)
    }
}

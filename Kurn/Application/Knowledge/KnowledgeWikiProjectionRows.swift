import Foundation
import KurnCore
import SwiftData

/// Completed projection jobs hold rebuildable, checksummed pages in the same
/// protected store as their canonical sources; no schema migration is needed.
enum KnowledgeWikiProjectionRows {
    static let pipeline = "knowledge-wiki-v1"
    static let byteLimit = 8 * 1_024 * 1_024

    static func key(scope: String, meetingIDs: Set<UUID>) throws -> String {
        let fields = [scope] + meetingIDs.map { $0.uuidString.lowercased() }.sorted()
        return pipeline + ":" + KnowledgeStoreRows.digest(try JSONEncoder().encode(fields))
    }

    static func payload(_ row: KnowledgeJob) throws -> KnowledgeWikiProjection {
        let value = try envelope(row)
        guard value.pages == (try KnowledgeWikiProjector.project(value.snapshot, narratives: value.pages.compactMap(\.narrative))) else {
            throw KnowledgeWikiStoreError.unreadableProjection
        }
        return value
    }

    /// Maintenance may inspect well-formed but structurally broken pages. The
    /// normal read/publication path still requires complete page validation.
    static func envelope(_ row: KnowledgeJob) throws -> KnowledgeWikiProjection {
        guard row.kindRaw == KnowledgeJobKind.projection.rawValue, row.stateRaw == KnowledgeJobState.succeeded.rawValue,
              row.pipelineVersion == pipeline, row.meetingID == nil, let bytes = row.checkpointData else {
            throw KnowledgeWikiStoreError.unreadableProjection
        }
        guard bytes.count <= byteLimit else { throw KnowledgeWikiProjectionError.projectionLimit }
        let result = JSONStorage.decodeAuthoritative(KnowledgeWikiProjection.self, from: bytes)
        if case .unsupportedVersion = result { throw KnowledgeWikiStoreError.unsupportedProjection }
        guard let value = result.decodedValue else { throw KnowledgeWikiStoreError.unreadableProjection }
        guard value.version == 1 else { throw KnowledgeWikiStoreError.unsupportedProjection }
        guard !value.sources.isEmpty, Set(value.sources.map(\.meetingID)).count == value.sources.count,
              row.idempotencyKey == (try key(scope: value.scope, meetingIDs: Set(value.sources.map(\.meetingID)))) else {
            throw KnowledgeWikiStoreError.unreadableProjection
        }
        return value
    }

    static func publish(_ expected: KnowledgeWikiProjectionSnapshot, narratives: [KnowledgeWikiNarrative], auth: KnowledgeWikiAuthorization,
                        container: ModelContainer, beforeSave: () throws -> Void) throws -> KnowledgeWikiProjection {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var published: KnowledgeWikiProjection?
            try context.transaction {
                let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: Set(expected.sources.map(\.meetingID)),
                    scope: expected.scope, auth: auth, in: context)
                let current = try KnowledgeWikiSourceRows.snapshot(sources: sources, in: context)
                guard current.sources == expected.sources, current.policyRevisionKey == expected.policyRevisionKey,
                      current.wiki == expected.wiki else { throw KnowledgeWikiStoreError.staleSnapshot }
                let pages = try KnowledgeWikiProjector.project(current.wiki, narratives: narratives)
                let result = KnowledgeWikiProjection(scope: current.scope, policyRevisionKey: current.policyRevisionKey,
                    sources: current.sources, snapshot: current.wiki, pages: pages)
                let key = try key(scope: current.scope, meetingIDs: Set(current.sources.map(\.meetingID)))
                let old = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.idempotencyKey == key })).first
                if let old { _ = try payload(old) } // Never replace unreadable/future bytes.
                let bytes = try KnowledgeStoreRows.authoritativeData(result)
                guard bytes.count <= byteLimit else { throw KnowledgeWikiProjectionError.projectionLimit }
                let job = old ?? KnowledgeJob(idempotencyKey: key, kind: .projection, pipelineVersion: pipeline)
                if old == nil { context.insert(job) }
                job.checkpointData = bytes
                job.stateRaw = KnowledgeJobState.succeeded.rawValue
                job.updatedAt = Date()
                try KnowledgeWikiOutboxRows.acknowledgeCovered(sources: sources, in: context)
                try Task.checkCancellation()
                try beforeSave()
                try context.save()
                published = result
            }
            guard let published else { throw KnowledgeWikiStoreError.invalidCanonical }
            return published
        } catch {
            context.rollback()
            throw error
        }
    }

    static func read(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeWikiAuthorization,
                     container: ModelContainer) throws -> KnowledgeWikiProjection? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: meetingIDs, scope: scope, auth: auth, in: context)
        let key = try key(scope: scope, meetingIDs: meetingIDs)
        guard let row = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.idempotencyKey == key })).first else { return nil }
        let stored = try payload(row)
        guard stored.sources == KnowledgeEntityResolutionRows.tokens(sources), stored.policyRevisionKey == sources.first?.policyRevisionKey,
              stored.snapshot.revision == (try KnowledgeStoreRows.latestRevision(in: context)) else { return nil }
        let current = try KnowledgeWikiSourceRows.snapshot(sources: sources, in: context)
        guard stored.snapshot == current.wiki else { return nil }
        return stored
    }

}

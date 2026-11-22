import Foundation
import KurnCore
import SwiftData

/// Discovery is bounded; mutation origin proofs are not a candidate page.
/// Audits pin exact origin jobs, so undo never depends on recent-job/UUID caps.
enum KnowledgeEntityOriginRows {
    static func entityIDs(_ job: KnowledgeJob, source: KnowledgeStoreSnapshot, historicalPolicies: Bool,
                          in context: ModelContext) throws -> Set<UUID>? {
        guard let identity = KnowledgeCompilationIdentity(idempotencyKey: job.idempotencyKey) else {
            throw KnowledgeEntityStoreError.unsupportedPayload
        }
        guard identity.scope == source.scope else { return nil }
        guard job.kindRaw == KnowledgeJobKind.extraction.rawValue, job.stateRaw == KnowledgeJobState.succeeded.rawValue,
              identity.meetingID == source.meetingID, job.meetingID == source.meetingID,
              identity.extractorVersion == job.pipelineVersion else { throw KnowledgeEntityStoreError.unreadablePayload }
        guard identity.schemaVersion == 1 else { throw KnowledgeEntityStoreError.unsupportedPayload }
        let id = job.id
        let revisions = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.jobID == id }))
        guard revisions.count == 1, let revision = revisions.first else { throw KnowledgeEntityStoreError.unreadablePayload }
        guard historicalPolicies || revision.policyRevisionKey == source.policyRevisionKey else { return nil }
        let provenance = try KnowledgeEntityResolutionRows.decode(KnowledgeCommitProvenance.self, job.checkpointData ?? Data())
        return Set(provenance.recordings.flatMap { $0.passes.flatMap { $0.entityIDs.values } })
    }

    static func prove(_ required: Set<UUID>, sources: [KnowledgeStoreSnapshot], historicalPolicies: Bool = false,
                      in context: ModelContext) throws -> [KnowledgeEntityOrigin] {
        guard !required.isEmpty else { return [] }
        var missing = required
        var origins: [KnowledgeEntityOrigin] = []
        for source in sources {
            let meetingID = source.meetingID
            let kind = KnowledgeJobKind.extraction.rawValue
            let succeeded = KnowledgeJobState.succeeded.rawValue
            var offset = 0
            while !missing.isEmpty {
                try Task.checkCancellation()
                var descriptor = FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
                    $0.meetingID == meetingID && $0.kindRaw == kind && $0.stateRaw == succeeded
                }, sortBy: [SortDescriptor(\KnowledgeJob.createdAt, order: .reverse), SortDescriptor(\KnowledgeJob.idempotencyKey)])
                descriptor.fetchLimit = 128
                descriptor.fetchOffset = offset
                let jobs = try context.fetch(descriptor)
                for job in jobs {
                    guard let ids = try entityIDs(job, source: source, historicalPolicies: historicalPolicies, in: context) else { continue }
                    for id in missing.intersection(ids) {
                        origins.append(KnowledgeEntityOrigin(entityID: id, meetingID: meetingID, jobID: job.id))
                        missing.remove(id)
                    }
                    if missing.isEmpty { break }
                }
                if jobs.count < 128 { break }
                offset += jobs.count
            }
            if missing.isEmpty { break }
        }
        guard missing.isEmpty else { throw KnowledgeEntityStoreError.scopeDenied }
        return origins.sorted { $0.entityID.uuidString < $1.entityID.uuidString }
    }

    static func verify(_ origins: [KnowledgeEntityOrigin], sources: [KnowledgeStoreSnapshot], in context: ModelContext) throws {
        let byMeeting = Dictionary(uniqueKeysWithValues: sources.map { ($0.meetingID, $0) })
        var jobs: [UUID: (meetingID: UUID, entities: Set<UUID>)] = [:]
        for origin in origins {
            guard let source = byMeeting[origin.meetingID] else { throw KnowledgeEntityStoreError.scopeDenied }
            let jobID = origin.jobID
            if jobs[jobID] == nil {
                guard let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == jobID })).first,
                      let ids = try entityIDs(job, source: source, historicalPolicies: true, in: context) else { throw KnowledgeEntityStoreError.scopeDenied }
                jobs[jobID] = (origin.meetingID, ids)
            }
            guard jobs[jobID]?.meetingID == origin.meetingID, jobs[jobID]?.entities.contains(origin.entityID) == true else { throw KnowledgeEntityStoreError.scopeDenied }
        }
    }

    static func entity(_ id: UUID, in context: ModelContext) throws -> KnowledgeEntity {
        guard let row = try context.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { $0.id == id })).first else {
            throw KnowledgeEntityStoreError.scopeDenied
        }
        return row
    }

    static func targetPath(_ start: UUID, in context: ModelContext) throws -> [UUID: KnowledgeEntity] {
        var rows: [UUID: KnowledgeEntity] = [:]
        var next: UUID? = start
        while let id = next {
            guard rows[id] == nil else { throw KnowledgeEntityResolutionError.redirectCycle }
            guard rows.count < 64 else { throw KnowledgeEntityResolutionError.redirectLimit }
            let row = try entity(id, in: context)
            rows[id] = row
            next = row.mergedIntoID
        }
        return rows
    }
}

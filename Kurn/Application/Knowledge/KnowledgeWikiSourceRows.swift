import Foundation
import KurnCore
import SwiftData

/// Reads facts only after source authorization. Each fact is anchored to one
/// succeeded compilation, its exact ref-map, and current transcript evidence.
enum KnowledgeWikiSourceRows {
    struct Origin {
        let entities: Set<UUID>
        let recordingID: UUID
        let fingerprint: String
        let attribution: String
    }

    static func sources(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeWikiAuthorization,
                        in context: ModelContext) throws -> [KnowledgeStoreSnapshot] {
        guard !meetingIDs.isEmpty, meetingIDs.count <= 16, meetingIDs.isSubset(of: auth.meetingIDs),
              !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scope.utf8.count <= 256 else {
            throw KnowledgeWikiStoreError.scopeDenied
        }
        try auth.authorize(classifications: [])
        let sources = try meetingIDs.sorted { $0.uuidString < $1.uuidString }.map {
            try KnowledgeStoreRows.readSnapshot(meetingID: $0, scope: scope, auth: auth.extraction, in: context)
        }
        for source in sources {
            if let id = source.contextPolicyID {
                guard auth.policies.contains(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else {
                    throw KnowledgeWikiStoreError.scopeDenied
                }
            }
        }
        try auth.authorize(classifications: sources.map(\.contextClassification))
        return sources
    }

    static func snapshot(sources: [KnowledgeStoreSnapshot], in context: ModelContext) throws -> KnowledgeWikiProjectionSnapshot {
        guard let first = sources.first else { throw KnowledgeWikiStoreError.scopeDenied }
        var facts: [KnowledgeWikiSnapshot.Fact] = []
        var entities: [UUID: KnowledgeWikiSnapshot.Entity] = [:]
        for source in sources {
            let meetingID = source.meetingID
            var descriptor = FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate { $0.sourceMeetingID == meetingID && $0.retractedAt == nil })
            descriptor.fetchLimit = KnowledgeWikiProjector.factLimit + 1
            let rows = try context.fetch(descriptor)
            guard rows.count <= KnowledgeWikiProjector.factLimit else { throw KnowledgeWikiProjectionError.projectionLimit }
            for row in rows {
                try Task.checkCancellation()
                guard let origin = try origin(row, source: source, in: context) else { continue }
                guard let fact = try KnowledgeWikiFactRows.fact(row, origin: origin, source: source, in: context) else { continue }
                let ids = Set([row.subjectEntityID] + (row.objectEntityID.map { [$0] } ?? []))
                var paths: [UUID: KnowledgeEntity] = [:]
                for id in ids { paths.merge(try KnowledgeEntityOriginRows.targetPath(id, in: context)) { old, _ in old } }
                do {
                    _ = try KnowledgeEntityOriginRows.prove(Set(paths.keys), sources: sources, in: context)
                } catch KnowledgeEntityStoreError.scopeDenied {
                    // A redirect outside the explicitly selected sources must
                    // disclose neither its target nor its name/aliases.
                    continue
                }
                let values = try paths.values.map { try entity($0) }
                for value in values { entities[value.id] = value }
                facts.append(fact)
                guard facts.count <= KnowledgeWikiProjector.factLimit, entities.count <= KnowledgeWikiProjector.entityLimit else {
                    throw KnowledgeWikiProjectionError.projectionLimit
                }
            }
        }
        let wiki = KnowledgeWikiSnapshot(revision: try KnowledgeStoreRows.latestRevision(in: context),
            entities: entities.values.sorted { $0.id.uuidString < $1.id.uuidString }, facts: facts.sorted { $0.id.uuidString < $1.id.uuidString })
        _ = try KnowledgeWikiProjector.project(wiki)
        return KnowledgeWikiProjectionSnapshot(scope: first.scope, policyRevisionKey: first.policyRevisionKey,
            sources: KnowledgeEntityResolutionRows.tokens(sources), wiki: wiki)
    }

    private static func entity(_ row: KnowledgeEntity) throws -> KnowledgeWikiSnapshot.Entity {
        guard let kind = KnowledgeEntityKind(rawValue: row.kindRaw), let review = KnowledgeReviewState(rawValue: row.reviewStateRaw),
              review.isVisible else { throw KnowledgeWikiStoreError.invalidCanonical }
        return KnowledgeWikiSnapshot.Entity(id: row.id, kind: kind, name: row.canonicalName,
            aliases: try KnowledgeEntityResolutionRows.decode([String].self, row.aliasesData), targetID: row.mergedIntoID)
    }

    private static func origin(_ row: KnowledgeAssertion, source: KnowledgeStoreSnapshot, in context: ModelContext) throws -> Origin? {
        let revisionID = row.revisionID
        guard let revision = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.id == revisionID })).first,
              let jobID = revision.jobID,
              let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == jobID })).first,
              let identity = KnowledgeCompilationIdentity(idempotencyKey: job.idempotencyKey) else { throw KnowledgeWikiStoreError.invalidCanonical }
        guard identity.scope == source.scope, revision.policyRevisionKey == source.policyRevisionKey else { return nil }
        _ = try KnowledgeEntityOriginRows.entityIDs(job, source: source, historicalPolicies: false, in: context)
        guard row.extractorVersion == identity.extractorVersion, row.contextID == source.contextID,
              row.predicateRegistryVersion == KnowledgePredicate.registryVersion else { throw KnowledgeWikiStoreError.invalidCanonical }
        let provenance = try KnowledgeEntityResolutionRows.decode(KnowledgeCommitProvenance.self, job.checkpointData ?? Data())
        var origins: [Origin] = []
        for recording in provenance.recordings {
            for pass in recording.passes where pass.assertionIDs.values.contains(row.id) {
                guard let anchor = pass.attributionAnchors[row.id.uuidString.lowercased()] else { throw KnowledgeWikiStoreError.invalidCanonical }
                origins.append(Origin(entities: Set(pass.entityIDs.values), recordingID: recording.recordingID,
                    fingerprint: recording.transcriptFingerprint, attribution: anchor))
            }
        }
        guard origins.count == 1, let origin = origins.first, origin.entities.contains(row.subjectEntityID),
              row.objectEntityID.map(origin.entities.contains) ?? true else { throw KnowledgeWikiStoreError.invalidCanonical }
        return origin
    }
}

import Foundation
import KurnCore
import SwiftData

/// Synchronous helpers under KnowledgeStore's serial executor. Names are only
/// read after all selected sources have passed live policy authorization.
enum KnowledgeEntityResolutionRows {
    static let entityLimit = 1_024
    static let historyLimit = 128
    static let reviewLimit = 128

    struct Pool {
        var rows: [UUID: KnowledgeEntity] = [:]
        var truncated = false

        func redirects() throws -> [UUID: KnowledgeEntityRedirect] {
            try Dictionary(uniqueKeysWithValues: rows.values.map { row in
                guard let kind = KnowledgeEntityKind(rawValue: row.kindRaw) else { throw KnowledgeEntityStoreError.unreadablePayload }
                return (row.id, KnowledgeEntityRedirect(id: row.id, kind: kind, targetID: row.mergedIntoID))
            })
        }
        func safeRedirects() throws -> [UUID: KnowledgeEntityRedirect] {
            let all = try redirects()
            var safe: [UUID: KnowledgeEntityRedirect] = [:]
            for (id, node) in all {
                do {
                    _ = try KnowledgeEntityRedirectGraph.resolve(id, nodes: all)
                    safe[id] = node
                } catch KnowledgeEntityResolutionError.missingEntity {
                    // An authorized source may redirect outside the selected
                    // origins. Do not disclose that target ID or its names.
                    continue
                }
            }
            return safe
        }

        func values() throws -> [KnowledgeEntityResolutionValue] {
            let safe = try safeRedirects()
            var values: [UUID: KnowledgeEntityResolutionValue] = [:]
            for row in rows.values where row.mergedIntoID == nil {
                if let value = try readValue(row) { values[row.id] = value }
            }
            for row in rows.values where row.mergedIntoID != nil && safe[row.id] != nil {
                let root = try KnowledgeEntityRedirectGraph.resolve(row.id, nodes: safe)
                guard let base = values[root], let alias = try readValue(row) else { continue }
                let aliases = Set(base.aliases + alias.aliases + [alias.name]).subtracting([base.name])
                values[root] = KnowledgeEntityResolutionValue(id: root, kind: base.kind, name: base.name, aliases: aliases.sorted())
            }
            return values.values.sorted { $0.id.uuidString < $1.id.uuidString }
        }

        private func readValue(_ row: KnowledgeEntity) throws -> KnowledgeEntityResolutionValue? {
            guard let state = KnowledgeReviewState(rawValue: row.reviewStateRaw),
                  let kind = KnowledgeEntityKind(rawValue: row.kindRaw) else { throw KnowledgeEntityStoreError.unreadablePayload }
            guard state.isVisible else { return nil }
            return KnowledgeEntityResolutionValue(id: row.id, kind: kind, name: row.canonicalName,
                aliases: try KnowledgeEntityResolutionRows.decode([String].self, row.aliasesData))
        }

    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ bytes: Data) throws -> Value {
        let result = JSONStorage.decodeAuthoritative(type, from: bytes)
        if case .unsupportedVersion = result { throw KnowledgeEntityStoreError.unsupportedPayload }
        guard let value = result.decodedValue else { throw KnowledgeEntityStoreError.unreadablePayload }
        return value
    }

    static func reviewPayload(_ row: KnowledgeReview) throws -> KnowledgeEntityReviewPayload {
        guard row.kindRaw == KnowledgeReviewItemKind.mergeCandidate.rawValue, let bytes = row.payloadData,
              KnowledgeReviewItemState(rawValue: row.stateRaw) != nil else { throw KnowledgeEntityStoreError.invalidReview }
        let payload = try decode(KnowledgeEntityReviewPayload.self, bytes)
        guard payload.version == 1 else { throw KnowledgeEntityStoreError.unsupportedPayload }
        guard (payload.candidate != nil) != (payload.merge != nil) else { throw KnowledgeEntityStoreError.invalidReview }
        return payload
    }

    static func sources(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeEntityResolutionAuthorization,
                        in context: ModelContext) throws -> [KnowledgeStoreSnapshot] {
        guard !meetingIDs.isEmpty, meetingIDs.count <= 16, !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              meetingIDs.isSubset(of: auth.meetingIDs), auth.extraction.decision(for: .appleOnDevice).isAllowed else {
            throw KnowledgeEntityStoreError.scopeDenied
        }
        return try meetingIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
            let source = try KnowledgeStoreRows.readSnapshot(meetingID: id, scope: scope, auth: auth.extraction, in: context)
            try KnowledgeStoreRows.authorize(auth.extraction, source: source, provider: .appleOnDevice)
            return source
        }
    }

    /// Provenance supplies origin bindings; a name or a scope label alone
    /// never grants access to an entity. Truncation is explicit in the DTO.
    static func pool(sources: [KnowledgeStoreSnapshot], includeHistoricalPolicies: Bool = false, in context: ModelContext) throws -> Pool {
        var ids: Set<UUID> = []
        var result = Pool()
        for source in sources {
            let meetingID = source.meetingID
            let kind = KnowledgeJobKind.extraction.rawValue
            let succeeded = KnowledgeJobState.succeeded.rawValue
            var descriptor = FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
                $0.meetingID == meetingID && $0.kindRaw == kind && $0.stateRaw == succeeded
            }, sortBy: [SortDescriptor(\KnowledgeJob.createdAt, order: .reverse)])
            descriptor.fetchLimit = historyLimit + 1
            let jobs = try context.fetch(descriptor)
            result.truncated = result.truncated || jobs.count > historyLimit
            for job in jobs.prefix(historyLimit) {
                guard let identity = KnowledgeCompilationIdentity(idempotencyKey: job.idempotencyKey), identity.scope == source.scope else { continue }
                guard identity.meetingID == source.meetingID, identity.extractorVersion == job.pipelineVersion else {
                    throw KnowledgeEntityStoreError.unreadablePayload
                }
                guard identity.schemaVersion == 1 else { throw KnowledgeEntityStoreError.unsupportedPayload }
                let jobID = job.id
                let revisions = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.jobID == jobID }))
                guard revisions.count == 1, let revision = revisions.first else { throw KnowledgeEntityStoreError.unreadablePayload }
                guard includeHistoricalPolicies || revision.policyRevisionKey == source.policyRevisionKey else { continue }
                let provenance = try decode(KnowledgeCommitProvenance.self, job.checkpointData ?? Data())
                for recording in provenance.recordings {
                    for pass in recording.passes { ids.formUnion(pass.entityIDs.values) }
                }
            }
        }
        result.truncated = result.truncated || ids.count > entityLimit
        let selected = Array(ids.sorted { $0.uuidString < $1.uuidString }.prefix(entityLimit))
        guard !selected.isEmpty else { return result }
        let rows = try context.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { selected.contains($0.id) }))
        guard rows.count == selected.count else { throw KnowledgeEntityStoreError.unreadablePayload }
        result.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return result
    }

    static func snapshot(sources: [KnowledgeStoreSnapshot], pool: Pool, in context: ModelContext) throws -> KnowledgeEntityResolutionSnapshot {
        guard let first = sources.first else { throw KnowledgeEntityStoreError.scopeDenied }
        let safe = try pool.safeRedirects()
        return KnowledgeEntityResolutionSnapshot(scope: first.scope, revision: try KnowledgeStoreRows.latestRevision(in: context),
            policyRevisionKey: first.policyRevisionKey, sources: tokens(sources), entities: try pool.values(),
            redirects: safe, isTruncated: pool.truncated || safe.count != pool.rows.count)
    }

    static func tokens(_ sources: [KnowledgeStoreSnapshot]) -> [KnowledgeEntityResolutionSnapshot.Source] {
        sources.map { .init(meetingID: $0.meetingID, fingerprint: $0.transcriptFingerprint) }
    }

    static func refreshed(_ expected: KnowledgeEntityResolutionSnapshot, auth: KnowledgeEntityResolutionAuthorization,
                          in context: ModelContext) throws -> [KnowledgeStoreSnapshot] {
        let current = try sources(meetingIDs: Set(expected.sources.map(\.meetingID)), scope: expected.scope, auth: auth, in: context)
        guard tokens(current) == expected.sources,
              current.first?.policyRevisionKey == expected.policyRevisionKey else { throw KnowledgeEntityStoreError.staleSnapshot }
        return current
    }
}

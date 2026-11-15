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
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            var committed: KnowledgeCommitReceipt?
            try context.transaction {
                let current = try KnowledgeStoreRows.readSnapshot(meetingID: request.snapshot.meetingID, scope: request.snapshot.scope, auth: auth, in: context)
                try KnowledgeStoreRows.authorize(auth, source: current, provider: request.provider)
                guard current.policyRevisionKey == request.snapshot.policyRevisionKey else { throw KnowledgeStoreError.policyChanged }
                guard current.transcriptFingerprint == request.snapshot.transcriptFingerprint else { throw KnowledgeStoreError.sourceChanged }
                let identity = try KnowledgeCompilationIdentity(scope: current.scope, meetingID: current.meetingID,
                    transcriptFingerprint: current.transcriptFingerprint, extractorVersion: request.extractorVersion, schemaVersion: request.schemaVersion)
                guard request.schemaVersion == 1 else { throw KnowledgeStoreError.invalidCompilation }
                let key = try identity.idempotencyKey()
                var jobs = FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.idempotencyKey == key })
                jobs.fetchLimit = 1
                let existing = try context.fetch(jobs).first
                if let existing {
                    guard existing.kindRaw == KnowledgeJobKind.extraction.rawValue, existing.meetingID == current.meetingID,
                          existing.pipelineVersion == request.extractorVersion,
                          KnowledgeJobState(rawValue: existing.stateRaw) != nil else { throw KnowledgeStoreError.invalidJob }
                    if existing.stateRaw == KnowledgeJobState.cancelled.rawValue { throw KnowledgeStoreError.cancelledJob }
                    if existing.stateRaw == KnowledgeJobState.succeeded.rawValue {
                        let jobID = existing.id
                        let rows = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.jobID == jobID }))
                        guard rows.count == 1, let revision = rows.first else { throw KnowledgeStoreError.invalidJob }
                        guard revision.policyRevisionKey == current.policyRevisionKey else { throw KnowledgeStoreError.policyChanged }
                        committed = receipt(revision, replay: true)
                        return
                    }
                }
                guard current.canonicalRevision == request.snapshot.canonicalRevision else { throw KnowledgeStoreError.staleRevision }
                let validated = try KnowledgeStoreRows.validate(request.compilations, against: current)
                let now = Date()
                let job = existing ?? KnowledgeJob(idempotencyKey: key, kind: .extraction,
                    meetingID: current.meetingID, pipelineVersion: request.extractorVersion, createdAt: now)
                if existing == nil { context.insert(job) }
                let revision = KnowledgeRevision(number: current.canonicalRevision + 1, jobID: job.id,
                    policyRevisionKey: current.policyRevisionKey, assertionCount: validated.reduce(0) { count, item in
                        count + item.documents.reduce(0) { $0 + $1.assertions.count }
                    }, createdAt: now)
                context.insert(revision)
                try KnowledgeStoreRows.retirePrevious(identity: identity, current: current, at: now, in: context)
                let provenance = try KnowledgeStoreRows.insert(validated, snapshot: current, revisionID: revision.id,
                    extractorVersion: request.extractorVersion, at: now, in: context)
                job.checkpointData = try JSONEncoder().encode(provenance)
                job.coverageData = try JSONEncoder().encode(validated.map { item in
                    KnowledgeCommitProvenance.Coverage(recordingID: item.source.id,
                        examinedSegmentIDs: item.source.segments.map { $0.id.uuidString.lowercased() })
                })
                job.strategyRaw = validated.contains { $0.compilation.strategy == "blocks" } ? "blocks" : "fullContext"
                job.stateRaw = KnowledgeJobState.succeeded.rawValue
                job.attempts = max(1, job.attempts)
                job.lastErrorCode = nil
                job.updatedAt = now
                try Task.checkCancellation()
                try beforeSave()
                try context.save()
                committed = receipt(revision, replay: false)
            }
            guard let committed else { throw KnowledgeStoreError.invalidCompilation }
            return committed
        } catch {
            context.rollback()
            throw error
        }
    }

    func pendingProjection() throws -> KnowledgeCommitReceipt? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.projectionPending },
            sortBy: [SortDescriptor(\KnowledgeRevision.number, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map { receipt($0, replay: false) }
    }

    /// A projection of N covers all earlier revisions. A stale worker must not
    /// clear the outbox after a newer canonical commit. K2 will publish page/
    /// index writes in this same boundary before acknowledging it.
    func acknowledgeProjection(upTo number: Int) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            try context.transaction {
                guard try KnowledgeStoreRows.latestRevision(in: context) == number else { throw KnowledgeStoreError.staleRevision }
                let rows = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.projectionPending && $0.number <= number }))
                for revision in rows { revision.projectionPending = false }
                try context.save()
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    private func receipt(_ revision: KnowledgeRevision, replay: Bool) -> KnowledgeCommitReceipt {
        KnowledgeCommitReceipt(revisionID: revision.id, number: revision.number, jobID: revision.jobID,
            assertionCount: revision.assertionCount, projectionPending: revision.projectionPending, isReplay: replay)
    }
}

import Foundation
import KurnCore
import SwiftData

extension KnowledgeStoreRows {
    // swiftlint:disable:next function_parameter_count
    static func commit(
        _ request: KnowledgeCommitRequest, auth: KnowledgeExtractionAuthorization,
        container: ModelContainer, beforeSave: @Sendable () throws -> Void
    ) throws -> KnowledgeCommitReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var committed: KnowledgeCommitReceipt?
            try context.transaction {
                let current = try KnowledgeStoreRows.readSnapshot(meetingID: request.snapshot.meetingID, scope: request.snapshot.scope, auth: auth, in: context)
                try KnowledgeStoreRows.authorize(auth, source: current, provider: request.provider)
                guard current.policyRevisionKey == request.snapshot.policyRevisionKey else { throw KnowledgeStoreError.policyChanged }
                guard current.transcriptFingerprint == request.snapshot.transcriptFingerprint else { throw KnowledgeStoreError.sourceChanged }
                let identity = try KnowledgeCompilationIdentity(scope: current.scope, meetingID: current.meetingID,
                    transcriptFingerprint: current.transcriptFingerprint, extractorVersion: request.extractorVersion, schemaVersion: request.schemaVersion, generation: request.generation)
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
                    if let replay = try completedReceipt(existing, identity: identity, current: current, in: context) {
                        committed = replay
                        return
                    }
                }
                if let existing, existing.checkpointData != nil {
                    _ = try KnowledgeQueueRows.envelope(existing)
                    guard request.lease != nil else { throw KnowledgeStoreError.invalidJob }
                }
                if let lease = request.lease {
                    guard lease.work.key == key, lease.work.provider == request.provider,
                          lease.work.compilation?.policyRevisionKey == current.policyRevisionKey else { throw KnowledgeStoreError.invalidJob }
                    try KnowledgeQueueRows.requireLease(lease, job: existing)
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
                let provenanceData = try authoritativeData(provenance)
                let coverageData = try authoritativeData(validated.map { item in
                    KnowledgeCommitProvenance.Coverage(recordingID: item.source.id,
                        examinedSegmentIDs: item.source.segments.map { $0.id.uuidString.lowercased() })
                })
                job.checkpointData = provenanceData
                job.coverageData = coverageData
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

    static func completedReceipt(_ job: KnowledgeJob, identity: KnowledgeCompilationIdentity,
                                 current: KnowledgeStoreSnapshot, in context: ModelContext) throws -> KnowledgeCommitReceipt? {
        guard job.stateRaw == KnowledgeJobState.succeeded.rawValue else { return nil }
        let jobID = job.id
        let rows = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.jobID == jobID }))
        guard rows.count == 1, let revision = rows.first else { throw KnowledgeStoreError.invalidJob }
        guard revision.policyRevisionKey == current.policyRevisionKey else { throw KnowledgeStoreError.policyChanged }
        try validateStoredProvenance(job)
        guard try canReplay(identity: identity, revision: revision, in: context) else { throw KnowledgeStoreError.obsoleteJob }
        return receipt(revision, replay: true)
    }

    static func replay(_ work: KnowledgeQueuedWork, auth: KnowledgeExtractionAuthorization, container: ModelContainer) throws -> KnowledgeCommitReceipt? {
        guard let intent = work.compilation, let identity = KnowledgeCompilationIdentity(idempotencyKey: work.key),
              identity.scope == intent.scope, identity.generation == work.generation,
              identity.meetingID == work.meetingID, identity.transcriptFingerprint == work.sourceFingerprint,
              identity.extractorVersion == work.pipelineVersion, identity.schemaVersion == 1 else { throw KnowledgeStoreError.invalidJob }
        let context = ModelContext(container)
        let current = try readSnapshot(meetingID: work.meetingID, scope: intent.scope, auth: auth, in: context)
        try authorize(auth, source: current, provider: work.provider)
        guard current.transcriptFingerprint == work.sourceFingerprint else { throw KnowledgeStoreError.sourceChanged }
        guard current.policyRevisionKey == intent.policyRevisionKey else { throw KnowledgeStoreError.policyChanged }
        let key = work.key
        guard let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.idempotencyKey == key })).first else { return nil }
        guard job.kindRaw == KnowledgeJobKind.extraction.rawValue, job.meetingID == work.meetingID,
              job.pipelineVersion == work.pipelineVersion else { throw KnowledgeStoreError.invalidJob }
        guard job.stateRaw != KnowledgeJobState.cancelled.rawValue else { throw KnowledgeStoreError.cancelledJob }
        return try completedReceipt(job, identity: identity, current: current, in: context)
    }

    static func receipt(_ revision: KnowledgeRevision, replay: Bool) -> KnowledgeCommitReceipt {
        KnowledgeCommitReceipt(revisionID: revision.id, number: revision.number, jobID: revision.jobID,
            assertionCount: revision.assertionCount, projectionPending: revision.projectionPending, isReplay: replay)
    }

    static func canReplay(identity: KnowledgeCompilationIdentity, revision: KnowledgeRevision, in context: ModelContext) throws -> Bool {
        let meetingID = identity.meetingID
        let jobs = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.meetingID == meetingID }))
        let ids = Set(jobs.filter { KnowledgeCompilationIdentity(idempotencyKey: $0.idempotencyKey)?.scope == identity.scope }.map(\.id))
        let number = revision.number
        let later = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.number > number }))
        guard !later.contains(where: { $0.jobID.map(ids.contains) ?? false }) else { return false }
        // A compilation in ANOTHER scope may also invalidate this source's
        // old evidence. Latest-in-scope alone cannot make that job current.
        let revisionID = revision.id
        let assertions = try context.fetch(FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate { $0.revisionID == revisionID }))
        guard assertions.count == revision.assertionCount, assertions.allSatisfy({ $0.retractedAt == nil }) else { return false }
        let evidence = try context.fetch(FetchDescriptor<KnowledgeEvidence>(predicate: #Predicate { $0.meetingID == meetingID }))
        let supported = Set(evidence.filter(\.isAvailable).map(\.assertionID))
        return Set(assertions.map(\.id)).isSubset(of: supported)
    }

    static func validateStoredProvenance(_ job: KnowledgeJob) throws {
        try requireReadable(JSONStorage.decodeAuthoritative(KnowledgeCommitProvenance.self, from: job.checkpointData ?? Data()))
        try requireReadable(JSONStorage.decodeAuthoritative([KnowledgeCommitProvenance.Coverage].self, from: job.coverageData ?? Data()))
    }

    private static func requireReadable<Value>(_ outcome: JSONDecodeOutcome<Value>) throws {
        switch outcome {
        case .value: return
        case .unsupportedVersion: throw KnowledgeStoreError.unsupportedProvenanceVersion
        case .corrupted, .empty: throw KnowledgeStoreError.corruptedProvenance
        }
    }
}

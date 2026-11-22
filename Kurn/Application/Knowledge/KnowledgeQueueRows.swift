import Foundation
import KurnCore
import SwiftData

/// Synchronous persistence helpers: contexts never cross an await or escape
/// the KnowledgeStore's serial executor. Canonical completed-job provenance
/// is never interpreted or overwritten as a working queue checkpoint.
enum KnowledgeQueueRows {
    private static func context(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    static func envelope(_ job: KnowledgeJob) throws -> KnowledgeQueueEnvelope {
        guard let data = job.checkpointData else { throw KnowledgeQueueError.unreadableCheckpoint }
        let result = JSONStorage.decodeAuthoritative(KnowledgeQueueEnvelope.self, from: data)
        if case .unsupportedVersion = result { throw KnowledgeQueueError.unsupportedCheckpoint }
        guard let value = result.decodedValue else { throw KnowledgeQueueError.unreadableCheckpoint }
        guard value.version == 1 else { throw KnowledgeQueueError.unsupportedCheckpoint }
        guard value.work.key == job.idempotencyKey, value.work.meetingID == job.meetingID,
              value.work.pipelineVersion == job.pipelineVersion, value.work.kind.rawValue == job.kindRaw else {
            throw KnowledgeQueueError.unreadableCheckpoint
        }
        return value
    }

    static func requireLease(_ handle: KnowledgeJobHandle, job: KnowledgeJob?) throws {
        guard let job, job.id == handle.id, job.stateRaw == KnowledgeJobState.running.rawValue else { throw KnowledgeQueueError.staleLease }
        let payload = try envelope(job)
        guard payload.leaseID == handle.leaseID, payload.work == handle.work else { throw KnowledgeQueueError.staleLease }
    }

    private static func record(_ job: KnowledgeJob) throws -> KnowledgeQueuedRecord {
        guard let state = KnowledgeJobState(rawValue: job.stateRaw) else { throw KnowledgeQueueError.unreadableCheckpoint }
        return KnowledgeQueuedRecord(id: job.id, state: state, code: job.lastErrorCode,
            envelope: state.isFinal ? nil : try envelope(job))
    }

    static func state(id: UUID, container: ModelContainer) throws -> KnowledgeJobState? {
        let context = context(container)
        guard let row = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == id })).first else { return nil }
        guard let state = KnowledgeJobState(rawValue: row.stateRaw) else { throw KnowledgeQueueError.unreadableCheckpoint }
        return state
    }

    static func erase(kind: KnowledgeJobKind, createdBefore: Date, container: ModelContainer) throws {
        let context = context(container)
        let kindRaw = kind.rawValue
        let rows = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
            $0.kindRaw == kindRaw && $0.createdAt <= createdBefore
        }))
        for row in rows where kind != .extraction || row.stateRaw != KnowledgeJobState.succeeded.rawValue { context.delete(row) }
        try context.save()
    }

    static func records(kinds: Set<String>, container: ModelContainer) throws -> [KnowledgeQueuedRecord] {
        let context = context(container)
        let pending = KnowledgeJobState.pending.rawValue
        let deferred = KnowledgeJobState.deferred.rawValue
        let running = KnowledgeJobState.running.rawValue
        let rows = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
            $0.stateRaw == pending || $0.stateRaw == deferred || $0.stateRaw == running
        }, sortBy: [SortDescriptor(\KnowledgeJob.createdAt)]))
        return try rows.filter { kinds.contains($0.kindRaw) }.map(record)
    }

    static func enqueue(_ requested: KnowledgeQueuedWork, explicitRetry: Bool, restartCompleted: Bool,
                        container: ModelContainer) throws -> KnowledgeQueuedRecord {
        guard requested.kind != .extraction || !restartCompleted else { throw KnowledgeStoreError.invalidJob }
        let context = context(container)
        var requested = requested
        // Repeated requests while paused/waiting join the same unfinished
        // article, including a fresh generation of an obsolete identity.
        if requested.kind == .meetingArticle {
            let meetingID = requested.meetingID
            let kind = KnowledgeJobKind.meetingArticle.rawValue
            let candidates = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
                $0.meetingID == meetingID && $0.kindRaw == kind
            }))
            for candidate in candidates where ["pending", "running", "deferred"].contains(candidate.stateRaw) {
                let old = try envelope(candidate).work
                if old.force == requested.force, old.generation == requested.generation,
                   old.provider == requested.provider, old.model == requested.model,
                   old.pipelineVersion == requested.pipelineVersion, old.sourceFingerprint == requested.sourceFingerprint,
                   old.explicitlyRequested == requested.explicitlyRequested {
                    requested = old
                    break
                }
            }
        }
        let key = requested.key
        let existing = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.idempotencyKey == key })).first
        if let existing {
            guard KnowledgeJobState(rawValue: existing.stateRaw) != nil else { throw KnowledgeQueueError.unsupportedCheckpoint }
            guard existing.kindRaw == requested.kind.rawValue, existing.meetingID == requested.meetingID,
                  existing.pipelineVersion == requested.pipelineVersion else { throw KnowledgeQueueError.unreadableCheckpoint }
            let obsoleteArticle = requested.kind == .meetingArticle
                && existing.stateRaw == KnowledgeJobState.cancelled.rawValue
                && ["source_changed", "provider_changed"].contains(existing.lastErrorCode ?? "")
            if restartCompleted, existing.stateRaw == KnowledgeJobState.succeeded.rawValue || obsoleteArticle {
                return try enqueue(requested.regenerated(), explicitRetry: explicitRetry, restartCompleted: false, container: container)
            }
            if explicitRetry, existing.stateRaw != KnowledgeJobState.running.rawValue,
               existing.stateRaw != KnowledgeJobState.succeeded.rawValue, existing.stateRaw != KnowledgeJobState.cancelled.rawValue {
                var payload = try envelope(existing)
                payload.failures = 0
                payload.leaseID = nil
                existing.stateRaw = KnowledgeJobState.pending.rawValue
                existing.lastErrorCode = nil
                existing.checkpointData = try KnowledgeStoreRows.authoritativeData(payload)
                try context.save()
            }
            return try record(existing)
        }
        let job = KnowledgeJob(idempotencyKey: requested.key, kind: requested.kind, meetingID: requested.meetingID,
            pipelineVersion: requested.pipelineVersion)
        job.checkpointData = try KnowledgeStoreRows.authoritativeData(KnowledgeQueueEnvelope(work: requested))
        context.insert(job)
        try context.save()
        return try record(job)
    }

    static func claim(id: UUID, container: ModelContainer) throws -> KnowledgeJobHandle? {
        let context = context(container)
        guard let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == id })).first,
              [KnowledgeJobState.pending.rawValue, KnowledgeJobState.deferred.rawValue].contains(job.stateRaw),
              job.lastErrorCode != "explicit_retry_required" else { return nil }
        var payload = try envelope(job)
        let leaseID = UUID()
        payload.leaseID = leaseID
        payload.hasStarted = false
        job.checkpointData = try KnowledgeStoreRows.authoritativeData(payload)
        job.stateRaw = KnowledgeJobState.running.rawValue
        job.attempts += 1
        job.updatedAt = Date()
        try context.save()
        return KnowledgeJobHandle(id: id, leaseID: leaseID, work: payload.work, isExplicit: false)
    }

    static func progress(_ handle: KnowledgeJobHandle, container: ModelContainer) throws -> Data? {
        let context = context(container)
        let id = handle.id
        guard let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == id })).first else {
            throw KnowledgeQueueError.staleLease
        }
        let payload = try envelope(job)
        guard job.stateRaw == KnowledgeJobState.running.rawValue, payload.leaseID == handle.leaseID else { throw KnowledgeQueueError.staleLease }
        return payload.progress
    }

    static func update(_ handle: KnowledgeJobHandle, container: ModelContainer, ignoreTerminal: Bool = false,
                       mutation: (KnowledgeJob, inout KnowledgeQueueEnvelope) throws -> Void) throws {
        let context = context(container)
        let id = handle.id
        guard let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == id })).first else {
            if ignoreTerminal { return }
            throw KnowledgeQueueError.staleLease
        }
        if [KnowledgeJobState.succeeded.rawValue, KnowledgeJobState.cancelled.rawValue].contains(job.stateRaw) {
            if ignoreTerminal { return }
            throw KnowledgeQueueError.staleLease
        }
        var payload = try envelope(job)
        guard job.stateRaw == KnowledgeJobState.running.rawValue, payload.leaseID == handle.leaseID else { throw KnowledgeQueueError.staleLease }
        try mutation(job, &payload)
        job.checkpointData = try KnowledgeStoreRows.authoritativeData(payload)
        job.updatedAt = Date()
        try context.save()
    }

    static func recover(id: UUID, outputCommitted: Bool, container: ModelContainer) throws {
        let context = context(container)
        guard let job = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.id == id })).first,
              ["running", "pending", "deferred"].contains(job.stateRaw) else { return }
        guard job.stateRaw == "running" || outputCommitted else { return }
        var payload = try envelope(job)
        payload.leaseID = nil
        job.stateRaw = (outputCommitted ? KnowledgeJobState.succeeded : .deferred).rawValue
        job.lastErrorCode = outputCommitted ? nil : (payload.work.provider.kind != .appleOnDevice && payload.hasStarted ? "explicit_retry_required" : "interrupted")
        job.checkpointData = try KnowledgeStoreRows.authoritativeData(payload)
        job.updatedAt = Date()
        try context.save()
    }

    static func cancel(kind: KnowledgeJobKind, createdBefore: Date, container: ModelContainer) throws {
        let context = context(container)
        let kindRaw = kind.rawValue
        let rows = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
            $0.kindRaw == kindRaw && $0.createdAt <= createdBefore
        }))
        for job in rows where ![KnowledgeJobState.succeeded.rawValue, KnowledgeJobState.cancelled.rawValue].contains(job.stateRaw) {
            var payload = try envelope(job)
            payload.leaseID = nil
            job.checkpointData = try KnowledgeStoreRows.authoritativeData(payload)
            job.stateRaw = KnowledgeJobState.cancelled.rawValue
            job.lastErrorCode = nil
            job.updatedAt = Date()
        }
        try context.save()
    }
}

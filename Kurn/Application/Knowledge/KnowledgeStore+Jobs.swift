import Foundation
import KurnCore
import SwiftData

extension KnowledgeStore {
    func enqueue(_ work: KnowledgeQueuedWork, explicitRetry: Bool, restartCompleted: Bool) throws -> KnowledgeQueuedRecord {
        try KnowledgeQueueRows.enqueue(work, explicitRetry: explicitRetry, restartCompleted: restartCompleted, container: modelContainer)
    }

    func jobState(id: UUID) throws -> KnowledgeJobState? {
        try KnowledgeQueueRows.state(id: id, container: modelContainer)
    }

    func eraseJobs(kind: KnowledgeJobKind, createdBefore: Date) throws {
        try KnowledgeQueueRows.erase(kind: kind, createdBefore: createdBefore, container: modelContainer)
    }

    func queuedJobs(kinds: Set<String>) throws -> [KnowledgeQueuedRecord] {
        try KnowledgeQueueRows.records(kinds: kinds, container: modelContainer)
    }

    func claimJob(id: UUID) throws -> KnowledgeJobHandle? {
        try KnowledgeQueueRows.claim(id: id, container: modelContainer)
    }

    func markJobStarted(_ handle: KnowledgeJobHandle) throws {
        try KnowledgeQueueRows.update(handle, container: modelContainer) { _, envelope in envelope.hasStarted = true }
    }

    func discardJob(_ handle: KnowledgeJobHandle, code: String) throws {
        try KnowledgeQueueRows.update(handle, container: modelContainer, ignoreTerminal: true) { job, envelope in
            job.stateRaw = KnowledgeJobState.cancelled.rawValue
            job.lastErrorCode = code
            envelope.leaseID = nil
        }
    }

    func jobProgress(_ handle: KnowledgeJobHandle) throws -> Data? {
        try KnowledgeQueueRows.progress(handle, container: modelContainer)
    }

    func storeJobProgress(_ data: Data, handle: KnowledgeJobHandle) throws {
        try KnowledgeQueueRows.update(handle, container: modelContainer) { job, envelope in
            envelope.progress = data
            job.lastErrorCode = nil
        }
    }

    func finishJob(_ handle: KnowledgeJobHandle, code: String? = nil, deferred: Bool = false, interrupted: Bool = false, mayHaveEgress: Bool = false) throws {
        try KnowledgeQueueRows.update(handle, container: modelContainer, ignoreTerminal: true) { job, envelope in
            if interrupted {
                job.stateRaw = KnowledgeJobState.deferred.rawValue
                job.lastErrorCode = handle.work.provider.kind != .appleOnDevice && mayHaveEgress ? "explicit_retry_required" : "interrupted"
            } else if deferred {
                job.stateRaw = KnowledgeJobState.deferred.rawValue
                job.lastErrorCode = code
            } else if let code {
                envelope.failures += 1
                job.stateRaw = (envelope.failures >= 3 ? KnowledgeJobState.failed : .deferred).rawValue
                job.lastErrorCode = code
            } else {
                guard handle.work.kind != .extraction else { throw KnowledgeStoreError.invalidCompilation }
                job.stateRaw = KnowledgeJobState.succeeded.rawValue
                job.lastErrorCode = nil
            }
            envelope.leaseID = nil
            envelope.hasStarted = false
        }
    }

    func recoverJob(id: UUID, outputCommitted: Bool) throws {
        try KnowledgeQueueRows.recover(id: id, outputCommitted: outputCommitted, container: modelContainer)
    }

    func cancelJobs(kind: KnowledgeJobKind, createdBefore: Date) throws {
        try KnowledgeQueueRows.cancel(kind: kind, createdBefore: createdBefore, container: modelContainer)
    }
}

/// Lazily constructs exactly one writer off the main actor per environment.
actor KnowledgeStoreHost {
    private let container: ModelContainer
    private var instance: KnowledgeStore?
    init(container: ModelContainer) { self.container = container }
    func writer() -> KnowledgeStore {
        if let instance { return instance }
        let writer = KnowledgeStore(modelContainer: container)
        instance = writer
        return writer
    }
}

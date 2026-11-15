import Foundation
import KurnCore
import Observation
import SwiftData

/// One retained queue per environment. Payloads/checkpoints are durable; tasks
/// are foreground/BG opportunities, never a promise that iOS will run them.
@MainActor
@Observable
final class KnowledgeJobQueue {
    enum Outcome { case completed, deferred, failed }
    typealias Handler = @MainActor (KnowledgeJobHandle) async throws -> Void
    typealias Recovery = @MainActor (KnowledgeQueuedWork) throws -> Bool
    typealias Erase = @MainActor (KnowledgeStore, KnowledgeJobKind, Date) async throws -> Void
    private struct CancellationRequest {
        let kind: KnowledgeJobKind
        let cutoff: Date
        let epoch: Int
    }

    let storeHost: KnowledgeStoreHost
    private let scheduler: ResourceScheduler
    private var handlers: [String: Handler] = [:]
    private var recovery: [String: Recovery] = [:]
    private var foreground: Bool
    private var recording = false
    private var backgroundOpportunity = false
    private var automaticBudget = 0
    private var explicitJobs: Set<UUID> = []
    private var runErrors: [UUID: Error] = [:]
    private var cancellationInProgress = false
    private var invalidationEpoch = 0
    private var pendingCancellation: CancellationRequest?
    @ObservationIgnored private let eraseJobs: Erase
    private(set) var activeJobID: UUID?
    private(set) var lastFailureCode: String?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationTask: Task<Void, Never>?

    init(container: ModelContainer, foreground: Bool = true, scheduler: ResourceScheduler = .shared,
         eraseJobs: @escaping Erase = { try await $0.eraseJobs(kind: $1, createdBefore: $2) }) {
        storeHost = KnowledgeStoreHost(container: container)
        self.foreground = foreground
        self.scheduler = scheduler
        self.eraseJobs = eraseJobs
        automaticBudget = foreground ? 5 : 0
    }

    func register(kind: KnowledgeJobKind, recovery: @escaping Recovery = { _ in false }, handler: @escaping Handler) {
        handlers[kind.rawValue] = handler
        self.recovery[kind.rawValue] = recovery
    }

    func setForeground(_ active: Bool) {
        if active && !foreground { automaticBudget = 5 }
        foreground = active
        if !active { pause() } else { wake() }
    }

    func setRecording(_ active: Bool) {
        recording = active
        if active { pause() } else { wake() }
    }

    func beginBackgroundOpportunity() async {
        backgroundOpportunity = true
        if !foreground { automaticBudget = 5 }
        wake()
        await drainTask?.value
    }

    func endBackgroundOpportunity() {
        backgroundOpportunity = false
        if !foreground { pause() }
    }

    func waitUntilIdle() async {
        await cancellationTask?.value
        await drainTask?.value
    }

    func writer() async -> KnowledgeStore { await storeHost.writer() }

    func progress(_ handle: KnowledgeJobHandle) async throws -> Data? {
        try await storeHost.writer().jobProgress(handle)
    }

    func checkpoint(_ data: Data, for handle: KnowledgeJobHandle) async throws {
        try Task.checkCancellation()
        try await storeHost.writer().storeJobProgress(data, handle: handle)
    }

    func submit(_ work: KnowledgeQueuedWork, explicit: Bool, restartCompleted: Bool = false) async throws -> Outcome {
        let record = try await storeHost.writer().enqueue(work, explicitRetry: explicit, restartCompleted: restartCompleted)
        if record.state == .succeeded { return .completed }
        if record.state == .failed { return .failed }
        if record.state == .cancelled { return .deferred }
        if cancellationInProgress {
            resumeCancellation()
            await cancellationTask?.value
        }
        guard canRun(record.envelope?.work ?? work) else { return .deferred }
        if explicit && foreground && record.state != .running { explicitJobs.insert(record.id) }
        wake()
        await drainTask?.value
        if explicitJobs.contains(record.id), canRun(record.envelope?.work ?? work) {
            wake()
            await drainTask?.value
        }
        if let error = runErrors.removeValue(forKey: record.id) { throw error }
        let records = try await storeHost.writer().queuedJobs(kinds: Set(handlers.keys))
        if let pending = records.first(where: { $0.id == record.id }) {
            return pending.state == .running ? .deferred : (pending.code == "work_failed" ? .failed : .deferred)
        }
        // Terminal rows are omitted from the pending query. Read the original
        // identity without restarting a completed job or granting another retry.
        let terminal = try await storeHost.writer().jobState(id: record.id)
        explicitJobs.remove(record.id)
        guard let terminal else { return .deferred }
        return terminal == .succeeded ? .completed : (terminal == .cancelled ? .deferred : .failed)
    }

    /// Stops publication immediately, then cancels only work predating this
    /// request. A fresh user request after Clear gets a new generation key.
    func cancel(kind: KnowledgeJobKind) {
        invalidationEpoch += 1
        pendingCancellation = CancellationRequest(kind: kind, cutoff: Date(), epoch: invalidationEpoch)
        cancellationInProgress = true
        pause()
        cancellationTask?.cancel()
        cancellationTask = nil
        resumeCancellation()
    }

    private func resumeCancellation() {
        guard let request = pendingCancellation, cancellationTask == nil else { return }
        cancellationTask = Task {
            do {
                let store = await storeHost.writer()
                try await eraseJobs(store, request.kind, request.cutoff)
                guard request.epoch == invalidationEpoch else { return }
                pendingCancellation = nil
                cancellationInProgress = false
                cancellationTask = nil
                lastFailureCode = nil
                wake()
            } catch {
                guard request.epoch == invalidationEpoch else { return }
                lastFailureCode = "queue_cancel_failed"
                cancellationTask = nil
                // Keep the publication barrier and original cutoff. A later
                // foreground/recording opportunity or submission retries it.
            }
        }
    }

    func mayPublish(_ handle: KnowledgeJobHandle) -> Bool {
        activeJobID == handle.id && canRun(handle.work) && !Task.isCancelled
    }

    func hasLocalWork() async -> Bool {
        guard let records = try? await storeHost.writer().queuedJobs(kinds: Set(handlers.keys)) else { return false }
        return records.contains { $0.envelope?.work.provider.kind == .appleOnDevice
            && !["explicit_retry_required", "feature_disabled", "provider_unavailable", "provider_blocked", "policy_denied", "cloud_review_required"].contains($0.code ?? "") }
    }

    private func canRun(_ work: KnowledgeQueuedWork) -> Bool {
        !cancellationInProgress && !recording && (foreground || (backgroundOpportunity && work.provider.kind == .appleOnDevice))
    }

    private func pause() {
        explicitJobs.removeAll()
        drainTask?.cancel()
    }

    private func wake() {
        if cancellationInProgress { resumeCancellation(); return }
        guard drainTask == nil, !recording, foreground || backgroundOpportunity else { return }
        drainTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await drain()
            drainTask = nil
            // A foreground/recording transition may have happened while the
            // cancelled task was winding down. Never overlap the old task.
            if Task.isCancelled, !recording, foreground || backgroundOpportunity { wake() }
        }
    }

    private func drain() async {
        var visited: Set<UUID> = []
        do {
            let store = await storeHost.writer()
            // No previous drain is alive when this starts. Recover orphaned
            // leases after crashes AND after a storage failure in this process.
            let interrupted = try await store.queuedJobs(kinds: Set(handlers.keys))
            for record in interrupted where record.state == .running || record.code == "explicit_retry_required" {
                guard let work = record.envelope?.work else { continue }
                let committed = try recovery[work.kind.rawValue]?(work) ?? false
                if record.state == .running || committed {
                    try await store.recoverJob(id: record.id, outputCommitted: committed)
                }
            }
            while !Task.isCancelled && visited.count < 64 {
                let records = try await store.queuedJobs(kinds: Set(handlers.keys))
                let eligible = records.filter {
                    !visited.contains($0.id) && $0.state != .running && $0.code != "explicit_retry_required"
                        && $0.envelope.map { canRun($0.work) } == true
                }
                let preferred = foreground ? eligible.first {
                    explicitJobs.contains($0.id) || ($0.envelope?.work.explicitlyRequested == true && $0.envelope?.failures == 0)
                } : nil
                let chosen = preferred ?? (automaticBudget > 0 ? eligible.first : nil)
                guard let chosen else { return }
                visited.insert(chosen.id)
                guard let claimed = try await store.claimJob(id: chosen.id) else { continue }
                let explicit = explicitJobs.remove(chosen.id) != nil
                let handle = KnowledgeJobHandle(id: claimed.id, leaseID: claimed.leaseID, work: claimed.work, isExplicit: explicit)
                let requested = foreground && (explicit || (handle.work.explicitlyRequested && chosen.envelope?.failures == 0))
                if !requested { automaticBudget -= 1 }
                let mayContinue = try await execute(handle, store: store, automatic: !requested)
                if !mayContinue { return }
            }
        } catch {
            activeJobID = nil
            lastFailureCode = "queue_storage_failed"
        }
    }

    private func execute(_ handle: KnowledgeJobHandle, store: KnowledgeStore, automatic: Bool) async throws -> Bool {
        runErrors[handle.id] = nil
        activeJobID = handle.id
        defer { activeJobID = nil }
        let epoch = invalidationEpoch
        var began = false
        do {
            try await withResourceReservation(.knowledgeGeneration(onDevice: handle.work.provider.kind == .appleOnDevice), on: scheduler) {
                try Task.checkCancellation()
                guard canRun(handle.work), epoch == invalidationEpoch else { throw CancellationError() }
                try await store.markJobStarted(handle)
                try Task.checkCancellation()
                guard canRun(handle.work), epoch == invalidationEpoch else { throw CancellationError() }
                began = true
                guard let handler = handlers[handle.work.kind.rawValue] else { throw KnowledgeQueueError.workFailed }
                try await handler(handle)
                try Task.checkCancellation()
                guard canRun(handle.work), epoch == invalidationEpoch else { throw CancellationError() }
            }
            try await store.finishJob(handle)
        } catch is CancellationError {
            let committed = try recovery[handle.work.kind.rawValue]?(handle.work) ?? false
            try await store.finishJob(handle, interrupted: !committed, mayHaveEgress: began)
            return false
        } catch let deferred as KnowledgeJobDeferred {
            try await store.finishJob(handle, code: deferred.reason.rawValue, deferred: true)
            if automatic { automaticBudget += 1 }
        } catch let obsolete as KnowledgeWorkObsolete {
            try await store.discardJob(handle, code: obsolete.rawValue)
        } catch {
            try await store.finishJob(handle, code: "work_failed")
            if runErrors.count >= 10 { runErrors.removeAll() }
            runErrors[handle.id] = error
            lastFailureCode = "work_failed"
            return false // Do not burn a batch against a failing provider.
        }
        return true
    }

}

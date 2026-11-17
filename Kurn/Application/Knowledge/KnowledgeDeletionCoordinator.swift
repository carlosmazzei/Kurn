import CoreData
import Foundation
import KurnCore
import Observation

/// Drains deletion tombstones (K2.8). A tombstone is written in the same
/// commit that deletes a meeting or recording (`MeetingLibrary`), or durably
/// before "Delete Knowledge" starts, so draining is idempotent: at launch,
/// on activation and after any store save, whatever is still pending is purged.
/// A failed purge keeps its tombstone and is retried at the next opportunity.
@MainActor
@Observable
final class KnowledgeDeletionCoordinator {
    typealias Purge = @MainActor (KnowledgeStore) async throws -> KnowledgeDeletionReceipt?

    private let queue: KnowledgeJobQueue
    @ObservationIgnored private let purge: Purge
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var reportedFailures: Set<String> = []
    @ObservationIgnored nonisolated(unsafe) private var saveObserver: NSObjectProtocol?
    private(set) var isDeletingCorpus = false
    private(set) var lastFailureCode: String?

    init(queue: KnowledgeJobQueue, purge: @escaping Purge = { try await $0.purgeNextDeletion() }) {
        self.queue = queue
        self.purge = purge
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    /// Every store save may have committed a tombstone (a meeting or recording
    /// deleted anywhere in the app). Saves are signals only; nothing is read
    /// from the notification.
    func observeStoreSaves() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    /// Starts (or re-arms) a drain. Coalesces: a request while one runs makes
    /// it look once more before finishing, so a tombstone committed mid-drain
    /// is never missed.
    func drain() {
        guard task == nil else { rerun = true; return }
        task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.rerun = false
                await self.purgeAll()
            } while self.rerun
            self.task = nil
        }
    }

    func waitUntilIdle() async {
        while let task { await task.value }
    }

    /// "Delete Knowledge" in Settings. The tombstone is saved first. Only an
    /// active canonical extraction is interrupted (`refresh` is producer-scoped,
    /// so a running wiki article continues); it could not publish anyway, since
    /// the purge removes its lease row and bumps the revision in one save.
    func deleteCorpus() async throws {
        isDeletingCorpus = true
        defer { isDeletingCorpus = false }
        try await queue.writer().requestCorpusDeletion()
        queue.refresh(kind: .extraction)
        drain()
        await waitUntilIdle()
        if let lastFailureCode { throw KnowledgeDeletionError.purgeFailed(lastFailureCode) }
    }

    private func purgeAll() async {
        let store = await queue.writer()
        while true {
            do {
                guard let receipt = try await purge(store) else {
                    lastFailureCode = nil
                    return
                }
                AppLog.persistence.atNotice.notice(
                    "knowledge deletion purged scope=\(receipt.scope.rawValue, privacy: .public) revision=\(receipt.revision, privacy: .public)")
            } catch {
                let code = (error as? KnowledgeStoreError)?.rawValue ?? "knowledge_deletion_failed"
                lastFailureCode = code
                // One event per distinct failure per process: every later store
                // save retries, and a persistent failure must not flood the log.
                if reportedFailures.insert(code).inserted {
                    ReliabilityLog.record(ReliabilityEvent(operationID: OperationID(), operation: "knowledge_deletion",
                        stage: "purge", outcome: .failed, code: code))
                }
                AppLog.persistence.atError.error("knowledge deletion purge failed code=\(error.publicLogCode, privacy: .public)")
                return
            }
        }
    }
}

enum KnowledgeDeletionError: Error, Equatable {
    case purgeFailed(String)
}

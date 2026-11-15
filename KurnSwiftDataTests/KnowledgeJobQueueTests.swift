import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeJobQueueTests {
    private func container() throws -> ModelContainer {
        let schema = Schema([KnowledgeJob.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func work(remote: Bool = false) throws -> KnowledgeQueuedWork {
        try KnowledgeQueuedWork.article(meetingID: UUID(), generator: "wiki-v1", provider: remote ? .openAI : .appleOnDevice,
            model: "test-model", fingerprint: String(repeating: "a", count: 64), force: false)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw KnowledgeQueueError.workFailed }
            await Task.yield()
        }
    }

    @Test func durableProgressAndLeaseChecksSurviveANewWriter() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let work = try work()
        let first = try await store.enqueue(work, explicitRetry: false, restartCompleted: false)
        let again = try await store.enqueue(work, explicitRetry: false, restartCompleted: false)
        #expect(first.id == again.id)
        let oldValue = try await store.claimJob(id: first.id)
        let old = try #require(oldValue)
        try await store.storeJobProgress(Data("progress".utf8), handle: old)
        let reopened = KnowledgeStore(modelContainer: container)
        try await reopened.recoverJob(id: first.id, outputCommitted: false)
        await #expect(throws: KnowledgeQueueError.staleLease) { try await store.storeJobProgress(Data(), handle: old) }
        let nextValue = try await reopened.claimJob(id: first.id)
        let next = try #require(nextValue)
        #expect(next.leaseID != old.leaseID)
        #expect(try await reopened.jobProgress(next) == Data("progress".utf8))
        try await reopened.finishJob(next)
        await #expect(throws: KnowledgeQueueError.staleLease) { try await reopened.storeJobProgress(Data(), handle: next) }
        #expect(try await reopened.queuedJobs(kinds: ["meetingArticle"]).isEmpty)
    }

    @Test func remoteRecoveryRequiresExplicitRetryOnlyAfterTheCallCouldHaveStarted() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let work = try work(remote: true)
        let record = try await store.enqueue(work, explicitRetry: false, restartCompleted: false)
        _ = try await store.claimJob(id: record.id)
        try await store.recoverJob(id: record.id, outputCommitted: false)
        let handleValue = try await store.claimJob(id: record.id)
        let handle = try #require(handleValue)
        try await store.markJobStarted(handle)
        try await store.recoverJob(id: record.id, outputCommitted: false)
        #expect(try await store.claimJob(id: record.id) == nil)
        let blocked = try await store.queuedJobs(kinds: ["meetingArticle"])
        #expect(blocked.first?.code == "explicit_retry_required")
        let retry = try await store.enqueue(work, explicitRetry: true, restartCompleted: false)
        #expect(retry.id == record.id)
        #expect(retry.code == nil)
        #expect(try await store.claimJob(id: record.id) != nil)
    }

    @Test func realFailuresAreBoundedAndManualRetryPreservesProgress() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let work = try work()
        let record = try await store.enqueue(work, explicitRetry: false, restartCompleted: false)
        for _ in 0..<3 {
            let handleValue = try await store.claimJob(id: record.id)
            let handle = try #require(handleValue)
            try await store.storeJobProgress(Data([1, 2]), handle: handle)
            try await store.finishJob(handle, code: "work_failed")
        }
        let failed = try await store.enqueue(work, explicitRetry: false, restartCompleted: false)
        #expect(failed.state == .failed)
        #expect(try await store.claimJob(id: record.id) == nil)
        _ = try await store.enqueue(work, explicitRetry: true, restartCompleted: false)
        let nextValue = try await store.claimJob(id: record.id)
        let next = try #require(nextValue)
        #expect(try await store.jobProgress(next) == Data([1, 2]))
    }

    @Test func futureCheckpointBytesArePreservedAndCancelInvalidatesTheLease() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let record = try await store.enqueue(work(), explicitRetry: false, restartCompleted: false)
        let handleValue = try await store.claimJob(id: record.id)
        let handle = try #require(handleValue)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<KnowledgeJob>()).first)
        let original = try #require(row.checkpointData)
        var raw = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        raw["version"] = 999
        let future = try JSONSerialization.data(withJSONObject: raw)
        row.checkpointData = future
        try context.save()
        await #expect(throws: KnowledgeQueueError.unsupportedCheckpoint) { try await store.queuedJobs(kinds: ["meetingArticle"]) }
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<KnowledgeJob>()).first?.checkpointData == future)
        row.checkpointData = original
        row.stateRaw = "future_state"
        try context.save()
        await #expect(throws: KnowledgeQueueError.unsupportedCheckpoint) {
            try await store.enqueue(handle.work, explicitRetry: true, restartCompleted: false)
        }
        row.stateRaw = "running"
        try context.save()
        try await store.cancelJobs(kind: .meetingArticle, createdBefore: Date())
        await #expect(throws: KnowledgeQueueError.staleLease) { try await store.storeJobProgress(Data(), handle: handle) }
        try await store.finishJob(handle, interrupted: true)
        let cancelled = try await store.enqueue(handle.work, explicitRetry: true, restartCompleted: false)
        #expect(cancelled.state == .cancelled)
    }

    @Test func completedCanonicalProvenanceIsNeverOverwrittenAsAQueueEnvelope() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let record = try await store.enqueue(work(), explicitRetry: false, restartCompleted: false)
        let handleValue = try await store.claimJob(id: record.id)
        let handle = try #require(handleValue)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<KnowledgeJob>()).first)
        let bytes = try KnowledgeStoreRows.authoritativeData(["canonical": true])
        row.stateRaw = "succeeded"
        row.checkpointData = bytes
        try context.save()
        try await store.finishJob(handle)
        let read = ModelContext(container)
        #expect(try read.fetch(FetchDescriptor<KnowledgeJob>()).first?.checkpointData == bytes)
        let rebuilt = try await store.enqueue(handle.work, explicitRetry: true, restartCompleted: true)
        #expect(rebuilt.id != record.id)
    }

    @Test func recordingAndForegroundGatesDeferWithoutExecuting() async throws {
        let container = try container()
        let queue = KnowledgeJobQueue(container: container, foreground: false)
        var calls = 0
        queue.register(kind: .meetingArticle) { _ in calls += 1 }
        _ = try await queue.submit(work(), explicit: false)
        #expect(calls == 0)
        queue.setRecording(true)
        queue.setForeground(true)
        await queue.waitUntilIdle()
        #expect(calls == 0)
        queue.setRecording(false)
        await queue.waitUntilIdle()
        #expect(calls == 1)
    }

    @Test func resourceWaitIsCancelledBeforeRecordingAndTheReservationDoesNotLeak() async throws {
        let container = try container()
        let scheduler = ResourceScheduler(totalWeight: 10)
        try await scheduler.acquire(weight: 10)
        let queue = KnowledgeJobQueue(container: container, scheduler: scheduler)
        var calls = 0
        queue.register(kind: .meetingArticle) { _ in calls += 1 }
        let task = Task { try await queue.submit(work(), explicit: false) }
        #if DEBUG
        try await eventually { await scheduler.waiterCountForTesting == 1 }
        #endif
        queue.setRecording(true)
        _ = try await task.value
        #expect(calls == 0)
        await scheduler.release(weight: 10)
        queue.setRecording(false)
        await queue.waitUntilIdle()
        #expect(calls == 1)
        try await scheduler.acquire(weight: 10)
        await scheduler.release(weight: 10)
    }

    @Test func backgroundWindowsRunOnlyLocalWork() async throws {
        let container = try container()
        let queue = KnowledgeJobQueue(container: container, foreground: false)
        var providers: [String] = []
        queue.register(kind: .meetingArticle) { providers.append($0.work.provider.id) }
        _ = try await queue.submit(work(remote: true), explicit: false)
        _ = try await queue.submit(work(), explicit: false)
        await queue.beginBackgroundOpportunity()
        queue.endBackgroundOpportunity()
        #expect(providers == [AIProvider.appleOnDevice.id])
        #expect(!(await queue.hasLocalWork()))
        let pending = try await queue.writer().queuedJobs(kinds: ["meetingArticle"])
        #expect(pending.count == 1)
        #expect(pending.first?.envelope?.work.provider == .openAI)
    }

    @Test func foregroundAutomaticBudgetIsNotResetByEverySubmission() async throws {
        let container = try container()
        let queue = KnowledgeJobQueue(container: container, foreground: false)
        var calls = 0
        queue.register(kind: .meetingArticle) { _ in calls += 1 }
        let store = await queue.writer()
        for _ in 0..<7 { _ = try await store.enqueue(work(), explicitRetry: false, restartCompleted: false) }
        queue.setForeground(true)
        await queue.waitUntilIdle()
        #expect(calls == 5)
        queue.setForeground(true)
        await queue.waitUntilIdle()
        #expect(calls == 5)
        _ = try await queue.submit(work(), explicit: true)
        #expect(calls == 6)
        queue.setForeground(false)
        queue.setForeground(true)
        await queue.waitUntilIdle()
        #expect(calls == 8)
    }

    @Test func outputAlreadySavedIsRecoveredWithoutRepeatingPaidWork() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let record = try await store.enqueue(work(remote: true), explicitRetry: false, restartCompleted: false)
        let handleValue = try await store.claimJob(id: record.id)
        let handle = try #require(handleValue)
        try await store.markJobStarted(handle)
        let queue = KnowledgeJobQueue(container: container, foreground: false)
        var calls = 0
        queue.register(kind: .meetingArticle, recovery: { _ in true }) { _ in calls += 1 }
        queue.setForeground(true)
        await queue.waitUntilIdle()
        #expect(calls == 0)
        #expect(try await store.queuedJobs(kinds: ["meetingArticle"]).isEmpty)
    }

    @Test func repeatedForcedRequestsCoalesceUntilTheFirstHasCompleted() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let meetingID = UUID()
        func request() throws -> KnowledgeQueuedWork {
            try KnowledgeQueuedWork.article(meetingID: meetingID, generator: "wiki-v1", provider: .openAI,
                model: "model", fingerprint: "source", force: true, explicit: true)
        }
        let first = try await store.enqueue(request(), explicitRetry: true, restartCompleted: true)
        let second = try await store.enqueue(request(), explicitRetry: true, restartCompleted: true)
        #expect(first.id == second.id)
        let handleValue = try await store.claimJob(id: first.id)
        let handle = try #require(handleValue)
        try await store.finishJob(handle)
        let third = try await store.enqueue(request(), explicitRetry: true, restartCompleted: true)
        #expect(third.id != first.id)
    }

    @Test func obsoleteArticleIdentityCanStartAgainWithoutRevivingDeliberateCancellation() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        for code in ["provider_changed", "source_changed", "user_cancelled"] {
            let work = try work()
            let first = try await store.enqueue(work, explicitRetry: false, restartCompleted: true)
            let claimed = try await store.claimJob(id: first.id)
            let handle = try #require(claimed)
            try await store.discardJob(handle, code: code)
            let next = try await store.enqueue(work, explicitRetry: false, restartCompleted: true)
            let again = try await store.enqueue(work, explicitRetry: false, restartCompleted: true)
            #expect(again.id == next.id)
            #expect((next.id == first.id) == (code == "user_cancelled"))
            #expect(try await store.jobState(id: first.id) == .cancelled)
        }
    }

    @Test func failedClearRetriesOnANewRequestAndKeepsTheOriginalCutoff() async throws {
        let container = try container()
        var fail = true
        let queue = KnowledgeJobQueue(container: container, foreground: false, eraseJobs: { store, kind, cutoff in
            if fail { throw KnowledgeQueueError.persistenceFailed }
            try await store.eraseJobs(kind: kind, createdBefore: cutoff)
        })
        var calls = 0
        queue.register(kind: .meetingArticle) { _ in calls += 1 }
        _ = try await queue.submit(work(), explicit: false)
        queue.cancel(kind: .meetingArticle)
        await queue.waitUntilIdle()
        #expect(queue.lastFailureCode == "queue_cancel_failed")
        #expect(calls == 0)
        fail = false
        _ = try await queue.submit(work(), explicit: true)
        queue.setForeground(true)
        await queue.waitUntilIdle()
        #expect(calls == 1)
        #expect(queue.lastFailureCode == nil)
        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<KnowledgeJob>()) == 1)
    }

    @Test func newClearGenerationDoesNotCoalesceWithWorkAwaitingErasure() async throws {
        let container = try container()
        let store = KnowledgeStore(modelContainer: container)
        let meetingID = UUID()
        func request(generation: String) throws -> KnowledgeQueuedWork {
            try KnowledgeQueuedWork.article(meetingID: meetingID, generator: "wiki-v1", provider: .openAI,
                model: "model", fingerprint: "source", force: false, generation: generation)
        }
        let old = try await store.enqueue(request(generation: "old"), explicitRetry: false, restartCompleted: true)
        let next = try await store.enqueue(request(generation: "new"), explicitRetry: false, restartCompleted: true)
        #expect(old.id != next.id)
    }

}
}

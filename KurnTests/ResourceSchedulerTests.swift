//
//  ResourceSchedulerTests.swift
//  KurnTests
//
//  H8 PR 17, item 3: proves the global weight-budget scheduler actually
//  enforces a cap (not just tracks a number), queues and later admits a
//  caller that doesn't fit, keeps the budget consistent under cancellation,
//  and pins the weight table's two documented invariants against
//  `TranscriptionService`'s own existing sequential/concurrent behavior.
//
//  Waiting for a waiter to actually be enqueued uses `waiterCountForTesting`
//  polled with `Task.yield()` (bounded), never a fixed `Task.sleep` — a
//  fixed delay would either be flaky under CI load or slow for no reason.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ResourceSchedulerTests {

    // The queue-introspection tests use the DEBUG-only `waiterCountForTesting`
    // and are absent from the Release-configuration lane.
    #if DEBUG
    @Test func acquireSucceedsImmediatelyWhenBudgetIsFree() async throws {
        let scheduler = ResourceScheduler(totalWeight: 10)
        try await scheduler.acquire(weight: 10)
        #expect(await scheduler.waiterCountForTesting == 0)
    }

    @Test func acquireQueuesWhenBudgetIsFullThenAdmitsAfterRelease() async throws {
        let scheduler = ResourceScheduler(totalWeight: 10)
        try await scheduler.acquire(weight: 10)

        let waiterTask = Task {
            try await scheduler.acquire(weight: 5)
        }

        try await waitUntilWaiterCount(1, on: scheduler)

        await scheduler.release(weight: 10)
        try await waiterTask.value
        #expect(await scheduler.waiterCountForTesting == 0)
    }

    @Test func lighterWaiterIsAdmittedAheadOfAHeavierOneStillQueued() async throws {
        // Skip-ahead admission: a heavy waiter stuck at the front must not
        // block a lighter one behind it that already fits the freed budget.
        let scheduler = ResourceScheduler(totalWeight: 10)
        try await scheduler.acquire(weight: 10) // holder A, used=10

        let heavyTask = Task {
            try await scheduler.acquire(weight: 8)
        }
        try await waitUntilWaiterCount(1, on: scheduler)

        let lightTask = Task {
            try await scheduler.acquire(weight: 3)
        }
        try await waitUntilWaiterCount(2, on: scheduler)

        // A releases 3: used=7, which fits light (7+3=10) but not heavy
        // (7+8=15) — light is admitted out of arrival order, heavy stays
        // queued.
        await scheduler.release(weight: 3)
        try await lightTask.value
        #expect(await scheduler.waiterCountForTesting == 1)

        // Light releases its own weight (simulating finished work): used=7,
        // still doesn't fit heavy (7+8=15).
        await scheduler.release(weight: 3)
        #expect(await scheduler.waiterCountForTesting == 1)

        // A releases the rest of its original 10 (7 more): used=0, which
        // now fits heavy.
        await scheduler.release(weight: 7)
        try await heavyTask.value
        #expect(await scheduler.waiterCountForTesting == 0)
    }

    @Test func cancellingAQueuedAcquireThrowsAndFreesItsSlot() async throws {
        let scheduler = ResourceScheduler(totalWeight: 10)
        try await scheduler.acquire(weight: 10)

        let waiterTask = Task {
            try await scheduler.acquire(weight: 5)
        }
        try await waitUntilWaiterCount(1, on: scheduler)

        waiterTask.cancel()
        let result = await waiterTask.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await scheduler.waiterCountForTesting == 0)

        // The cancelled waiter must not have reserved any budget: releasing
        // the original holder's weight should immediately bring usage to
        // zero, provable by a fresh full-budget acquire succeeding at once.
        await scheduler.release(weight: 10)
        try await scheduler.acquire(weight: 10)
    }

    @Test func acquireThrowsImmediatelyForAnAlreadyCancelledTask() async throws {
        let scheduler = ResourceScheduler(totalWeight: 10)
        let result = await Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            try await scheduler.acquire(weight: 1)
        }.result
        #expect(throws: CancellationError.self) { try result.get() }
        // Nothing was reserved — the whole budget is still available for a
        // fresh acquire to succeed immediately.
        try await scheduler.acquire(weight: 10)
    }

    @Test func aWeightAboveTheWholeBudgetRunsAloneInsteadOfNever() async throws {
        let scheduler = ResourceScheduler(totalWeight: 10)
        try await scheduler.acquire(weight: 25)
        #expect(await scheduler.waiterCountForTesting == 0)

        let waiterTask = Task {
            try await scheduler.acquire(weight: 1)
        }
        try await waitUntilWaiterCount(1, on: scheduler)

        await scheduler.release(weight: 25)
        try await waiterTask.value
    }

    #endif

    // MARK: - Scoped reservation

    @Test func scopedReservationReleasesBeforeReturningItsResult() async throws {
        let scheduler = ResourceScheduler(totalWeight: 100)
        let value = try await withResourceReservation(.preprocessing, on: scheduler) { 42 }
        #expect(value == 42)
        // The release is not a detached step: by the time the value is
        // observed the full budget is back and admits a whole-budget acquire.
        try await scheduler.acquire(weight: 100)
    }

    @Test func scopedReservationReleasesWhenTheBodyThrows() async throws {
        struct BodyError: Error {}
        let scheduler = ResourceScheduler(totalWeight: 100)
        await #expect(throws: BodyError.self) {
            try await withResourceReservation(.preprocessing, on: scheduler) {
                throw BodyError()
            }
        }
        try await scheduler.acquire(weight: 100)
    }

    @Test func scopedReservationReleasesWhenTheBodyIsCancelledMidway() async throws {
        let scheduler = ResourceScheduler(totalWeight: 100)
        let bodyStarted = AsyncStream<Void>.makeStream()
        let task = Task {
            try await withResourceReservation(.preprocessing, on: scheduler) {
                bodyStarted.continuation.yield()
                try await Task.sleep(for: .seconds(60))
            }
        }
        for await _ in bodyStarted.stream { break }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        try await scheduler.acquire(weight: 100)
    }

    #if DEBUG
    @Test func scopedReservationCancelledWhileQueuedNeverRunsItsBody() async throws {
        let scheduler = ResourceScheduler(totalWeight: 100)
        try await scheduler.acquire(weight: 100)

        let bodyRan = Ran()
        let task = Task {
            try await withResourceReservation(.preprocessing, on: scheduler) {
                bodyRan.mark()
            }
        }
        try await waitUntilWaiterCount(1, on: scheduler)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!bodyRan.value)
        #expect(await scheduler.waiterCountForTesting == 0)

        await scheduler.release(weight: 100)
        try await scheduler.acquire(weight: 100)
    }

    #endif

    // MARK: - Weight table invariants

    @Test func cloudTranscriptionFitsAlongsideEveryDiarizationEngine() {
        let asr = ResourceWorkKind.transcription(.whisperAPI).weight
        for engine in DiarizationEngine.allCases {
            let total = asr + ResourceWorkKind.diarization(engine).weight
            #expect(
                total <= ResourceScheduler.defaultTotalWeight,
                "cloud transcription + \(engine) should fit together, got \(total)"
            )
        }
    }

    @Test func onDeviceTranscriptionNeverFitsAlongsideNeuralDiarization() {
        // Mirrors `TranscriptionService.transcribe`'s own hardcoded rule:
        // any on-device engine is never run concurrently with FluidAudio or
        // sherpa-onnx diarization, because doing so risks a jetsam. The
        // scheduler's weights must refuse the same combination rather than
        // silently allowing it.
        let onDeviceEngines: [TranscriptionEngine] = [.appleSpeech, .fluidAudioParakeet, .whisperCpp]
        let neuralDiarizers: [DiarizationEngine] = [.fluidAudio, .sherpaOnnx]
        for asrEngine in onDeviceEngines {
            for diarizationEngine in neuralDiarizers {
                let total = ResourceWorkKind.transcription(asrEngine).weight
                    + ResourceWorkKind.diarization(diarizationEngine).weight
                #expect(
                    total > ResourceScheduler.defaultTotalWeight,
                    "\(asrEngine) + \(diarizationEngine) should not fit together, got \(total)"
                )
            }
        }
    }

    // MARK: - Helpers

    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func mark() { lock.withLock { flag = true } }
    }

    #if DEBUG
    /// Polls `waiterCountForTesting` until it reaches `count`, yielding
    /// between checks instead of sleeping a fixed duration. Bounded so a
    /// real bug (the waiter never gets enqueued) fails the assertion right
    /// after rather than hanging the test suite.
    private func waitUntilWaiterCount(
        _ count: Int,
        on scheduler: ResourceScheduler,
        maxAttempts: Int = 10_000
    ) async throws {
        var attempts = 0
        while await scheduler.waiterCountForTesting != count, attempts < maxAttempts {
            await Task.yield()
            attempts += 1
        }
        #expect(await scheduler.waiterCountForTesting == count)
    }
    #endif
}

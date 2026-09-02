//
//  ResourceScheduler.swift
//  Kurn
//
//  H8 PR 17, item 3: "a resource-aware scheduler/cap so concurrent
//  preprocessing, ASR, diarization, enhancement and model loading cannot
//  each pass an independent preflight and then exceed memory together."
//
//  Before this file, every stage's admission check was a preflight against
//  disk/memory-pressure state alone (`ResourceGuard`) — each one answers "is
//  the device healthy right now," never "is enough of the device's budget
//  still free for me specifically." Two concurrent transcriptions of
//  different recordings, each picking a large on-device ASR model, could
//  both pass their own preflight and then both allocate that model's
//  inference activations at once — the exact jetsam risk
//  `TranscriptionService.transcribe`'s own comment already names for a
//  *single* recording's ASR-vs-diarizer overlap, just one layer up, across
//  recordings instead of within one.
//
//  `ResourceScheduler` is a single global actor-isolated weight budget.
//  Each stage acquires a `ResourceWorkKind`'s weight before it starts and
//  releases it when it finishes (successfully, on error, or on
//  cancellation); a request that would push the budget over its cap waits,
//  admitted once enough other work has released.
//
//  What this deliberately does not do: replace or duplicate
//  `TranscriptionService.transcribe`'s existing compile-time sequential/
//  concurrent branch for one recording's own ASR-vs-diarization overlap —
//  that branch is left exactly as it is. The weights below are chosen so
//  the *combination* this scheduler would refuse (a heavy on-device ASR
//  engine's weight plus a neural diarization engine's weight exceeding the
//  budget) already matches what that branch never attempts concurrently,
//  so the two mechanisms agree rather than fight; see the header on
//  `ResourceWorkKind` for the reasoning.
//

import Foundation
import KurnCore

/// The five categories item 3 names, each carrying enough information to
/// pick a weight per engine where engines differ meaningfully in cost.
enum ResourceWorkKind: Sendable, Equatable {
    case preprocessing
    case transcription(TranscriptionEngine)
    case diarization(DiarizationEngine)
    case enhancement
    case modelLoading

    /// Abstract units against `ResourceScheduler.defaultTotalWeight`'s
    /// budget of 100 — a first-cut estimate of relative memory cost, not a
    /// measurement against a real jetsam threshold (no such benchmark
    /// exists anywhere in this codebase as of H8 PR 17; see the PR's known
    /// gap). Two invariants the numbers below were chosen to preserve,
    /// since they encode a real constraint `TranscriptionService` already
    /// depends on elsewhere:
    ///   - `.transcription(.whisperAPI)` (network-bound, keeps almost
    ///     nothing on-device) plus any diarization engine must fit
    ///     together — `TranscriptionService.transcribe` already runs those
    ///     two concurrently for cloud transcription.
    ///   - `.transcription` for any *on-device* engine plus
    ///     `.diarization(.fluidAudio)`/`.diarization(.sherpaOnnx)` must
    ///     NOT fit together — `TranscriptionService.transcribe` already
    ///     never attempts that combination concurrently, for exactly the
    ///     jetsam reason this scheduler exists to generalize across
    ///     recordings.
    var weight: Int {
        switch self {
        case .preprocessing:
            return 15
        case .transcription(let engine):
            switch engine {
            case .whisperAPI: return 5
            case .appleSpeech: return 35
            case .fluidAudioParakeet, .whisperCpp: return 60
            }
        case .diarization(let engine):
            switch engine {
            case .heuristic: return 10
            case .fluidAudio, .sherpaOnnx: return 50
            }
        case .enhancement:
            return 30
        case .modelLoading:
            return 40
        }
    }
}

/// A single global weight budget, shared across every concurrent recording.
/// `acquire(weight:)` suspends until enough budget is free; `release(weight:)`
/// returns it and admits whichever queued waiters now fit.
///
/// An `actor` rather than a `DispatchSemaphore`/lock: every operation here is
/// already `async`, and an actor gives cancellation-safe suspension
/// (`withTaskCancellationHandler`) for free instead of hand-rolled queue
/// bookkeeping under a lock.
actor ResourceScheduler {
    static let shared = ResourceScheduler()

    /// The full budget concurrent work may consume at once. See
    /// `ResourceWorkKind.weight`'s header for what this number is (and
    /// isn't) calibrated against.
    static let defaultTotalWeight = 100

    private struct Waiter {
        let id: UUID
        let weight: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let totalWeight: Int
    private var usedWeight = 0
    private var waiters: [Waiter] = []

    /// `totalWeight` is injectable so tests can use a small budget to force
    /// contention deterministically, without needing real heavy work.
    /// Production code always uses `.shared`.
    init(totalWeight: Int = ResourceScheduler.defaultTotalWeight) {
        self.totalWeight = totalWeight
    }

    /// Reserve `weight` units, waiting if the budget is currently full.
    /// Cancelling the calling task while queued removes the waiter and
    /// throws `CancellationError` instead of leaking a slot nothing will
    /// ever release.
    func acquire(weight: Int) async throws {
        try Task.checkCancellation()
        guard usedWeight + weight > totalWeight else {
            usedWeight += weight
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, weight: weight, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    /// Return `weight` units to the budget and admit whichever queued
    /// waiters now fit.
    func release(weight: Int) {
        usedWeight = max(0, usedWeight - weight)
        admitWaitersIfPossible()
    }

    #if DEBUG
    /// Test-only introspection: how many callers are currently queued
    /// waiting for budget. Exposed rather than kept private so a test can
    /// poll for a waiter to actually be enqueued before proceeding, instead
    /// of guessing a fixed delay.
    var waiterCountForTesting: Int { waiters.count }
    #endif

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Scans every waiter in arrival order and admits each one whose weight
    /// currently fits, rather than only ever looking at the front of the
    /// queue. A single heavy waiter stuck at the front (e.g. a large
    /// on-device ASR load waiting on another recording's diarization to
    /// finish) must not also block a lighter one behind it — enhancement
    /// rendering, say — that already fits the free budget on its own.
    private func admitWaitersIfPossible() {
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            guard usedWeight + waiter.weight <= totalWeight else {
                index += 1
                continue
            }
            waiters.remove(at: index)
            usedWeight += waiter.weight
            waiter.continuation.resume()
        }
    }
}

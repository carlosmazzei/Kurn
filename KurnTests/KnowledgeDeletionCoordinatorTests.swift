import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// The drain loop around `KnowledgeStore.purgeNextDeletion` (K2.8). The purge
/// itself is covered against a real store in `KnowledgeDeletionTests`.
@MainActor
struct KnowledgeDeletionCoordinatorTests {
    @MainActor private final class Script {
        var results: [Result<KnowledgeDeletionReceipt?, Error>]
        var calls = 0
        init(_ results: [Result<KnowledgeDeletionReceipt?, Error>]) { self.results = results }
        func next() throws -> KnowledgeDeletionReceipt? {
            calls += 1
            return results.isEmpty ? nil : try results.removeFirst().get()
        }
    }

    private func receipt(_ revision: Int) -> KnowledgeDeletionReceipt {
        KnowledgeDeletionReceipt(scope: .meeting, meetingID: UUID(), revision: revision)
    }

    private func queue() -> KnowledgeJobQueue { KnowledgeJobQueue(container: TestModelContainer.make()) }

    @Test func drainPurgesUntilNoTombstoneIsLeft() async {
        let script = Script([.success(receipt(1)), .success(receipt(2)), .success(nil)])
        let coordinator = KnowledgeDeletionCoordinator(queue: queue(), purge: { _ in try script.next() })
        coordinator.drain(); await coordinator.waitUntilIdle()
        #expect(script.calls == 3 && coordinator.lastFailureCode == nil)
    }

    @MainActor private final class Rearm {
        weak var coordinator: KnowledgeDeletionCoordinator?
        var calls = 0
    }

    @Test func aRequestDuringADrainLooksOnceMore() async {
        let rearm = Rearm()
        let coordinator = KnowledgeDeletionCoordinator(queue: queue(), purge: { _ in
            rearm.calls += 1
            // A tombstone committed while this drain runs re-arms it.
            if rearm.calls == 1 { rearm.coordinator?.drain() }
            return nil
        })
        rearm.coordinator = coordinator
        coordinator.drain(); await coordinator.waitUntilIdle()
        #expect(rearm.calls == 2)
    }

    /// A container whose main context is never created, as the Knowledge
    /// store's container is only written from its own actor.
    private static func backgroundContainer() -> ModelContainer {
        let schema = Schema(KurnModelGraph.currentModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do { return try ModelContainer(for: schema, configurations: [configuration]) } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }

    /// Blocks the main thread, as a store transaction running on it does.
    /// Generous, because a loaded test host can be slow to start the saver.
    private func blockMain(until saved: DispatchSemaphore) -> DispatchTimeoutResult {
        saved.wait(timeout: .now() + 30)
    }

    @Test func aStoreSaveNeverWaitsForTheMainThreadAndStillDrains() async {
        let script = Script([])
        let coordinator = KnowledgeDeletionCoordinator(queue: queue(), purge: { _ in try script.next() })
        coordinator.observeStoreSaves()
        let container = Self.backgroundContainer(), saved = DispatchSemaphore(value: 0)
        // A real transaction, as the store's publish makes, on its own thread
        // so a busy dispatch pool cannot delay it. Its save posts the
        // did-save notification synchronously; an observer queue would make
        // that post wait for the blocked main thread.
        Thread {
            let context = ModelContext(container)
            try? context.transaction { context.insert(Meeting(title: "Synthetic save")) }
            saved.signal()
        }.start()
        #expect(blockMain(until: saved) == .success)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while script.calls == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        await coordinator.waitUntilIdle()
        #expect(script.calls >= 1)
    }

    @Test func aFailureStopsTheDrainKeepsItsCodeAndAClearRunResetsIt() async {
        let script = Script([.failure(KnowledgeStoreError.invalidJob), .success(nil)])
        let coordinator = KnowledgeDeletionCoordinator(queue: queue(), purge: { _ in try script.next() })
        coordinator.drain(); await coordinator.waitUntilIdle()
        #expect(script.calls == 1 && coordinator.lastFailureCode == KnowledgeStoreError.invalidJob.rawValue)
        coordinator.drain(); await coordinator.waitUntilIdle()
        #expect(script.calls == 2 && coordinator.lastFailureCode == nil)
    }

    @Test func corpusDeletionWritesItsTombstoneBeforePurgingAndSurfacesAFailedPurge() async throws {
        let container = TestModelContainer.make()
        let jobs = KnowledgeJobQueue(container: container)
        // Records how many tombstones the purge found pending when it ran.
        let script = Script([])
        let coordinator = KnowledgeDeletionCoordinator(queue: jobs, purge: { store in
            script.calls = try await store.pendingDeletionCount()
            throw KnowledgeStoreError.invalidJob
        })
        await #expect(throws: KnowledgeDeletionError.purgeFailed(KnowledgeStoreError.invalidJob.rawValue)) {
            try await coordinator.deleteCorpus()
        }
        #expect(script.calls == 1 && !coordinator.isDeletingCorpus)
        // The tombstone stays for the next launch or activation.
        let kind = KnowledgeJobKind.deletion.rawValue
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == kind })) == 1)
    }

    @Test func libraryDeletionsCommitTheirTombstoneWithTheSource() throws {
        let context = ModelContext(TestModelContainer.make())
        let library = MeetingLibrary(context: context)
        let first = try library.createMeeting(title: "Synthetic first")
        let second = try library.createMeeting(title: "Synthetic second")
        let kept = try library.createMeeting(title: "Synthetic kept")
        let untranscribed = Recording(meeting: kept, fileName: "synthetic-missing-a.m4a", duration: 1)
        let transcribed = Recording(meeting: kept, fileName: "synthetic-missing-b.m4a", duration: 1)
        context.insert(untranscribed); context.insert(transcribed)
        let transcript = Transcript(recording: transcribed, segments: [], language: "en")
        context.insert(transcript); transcribed.transcript = transcript
        try context.save()
        let ids = (first.id, second.id, kept.id)

        try library.deleteMeeting(first)
        try library.deleteMeetings([second])
        // Nothing was compiled from audio that never had a transcript.
        try library.deleteRecording(untranscribed)
        try library.deleteRecording(transcribed)

        let kind = KnowledgeJobKind.deletion.rawValue
        let rows = try ModelContext(context.container).fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == kind }))
        let keys = Set(rows.map(\.idempotencyKey))
        #expect(keys == [KnowledgeDeletionRows.key(.meeting, meetingID: ids.0), KnowledgeDeletionRows.key(.meeting, meetingID: ids.1),
                         KnowledgeDeletionRows.key(.source, meetingID: ids.2)])
        #expect(rows.allSatisfy { $0.stateRaw == KnowledgeJobState.pending.rawValue && $0.pipelineVersion == KnowledgeDeletionRows.pipeline })
    }
}

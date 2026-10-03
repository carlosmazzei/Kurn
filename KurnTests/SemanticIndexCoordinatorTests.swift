//
//  SemanticIndexCoordinatorTests.swift
//  KurnTests
//
//  `SemanticIndexCoordinator` over an in-memory store with a deterministic
//  embedder: a meeting's passages are replaced wholesale, an embedder failure
//  keeps what was there, and the backfill and rebuild runs pick exactly the
//  meetings whose index is missing or was built by another model.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SemanticIndexCoordinatorTests {

    private struct EmbedderDown: Error {}

    private final class ScriptedEmbedder: TextEmbedding, @unchecked Sendable {
        let modelIdentifier: String
        private let lock = NSLock()
        private var _calls = 0
        private var _failure: Error?
        private var _emptyVectors = false

        init(modelIdentifier: String = "stub-v1") {
            self.modelIdentifier = modelIdentifier
        }

        var calls: Int { lock.withLock { _calls } }
        func fail(with error: Error?) { lock.withLock { _failure = error } }
        func returnEmptyVectors() { lock.withLock { _emptyVectors = true } }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            let (failure, empty) = lock.withLock { () -> (Error?, Bool) in
                _calls += 1
                return (_failure, _emptyVectors)
            }
            if let failure { throw failure }
            return texts.map { _ in empty ? [] : [1, 0, 0] }
        }
    }

    @MainActor
    private struct Harness {
        let context: ModelContext
        let embedder: ScriptedEmbedder
        let settings: AppSettings
        let coordinator: SemanticIndexCoordinator

        init(enabled: Bool = true, withSettings: Bool = true) {
            context = ModelContext(TestModelContainer.make())
            embedder = ScriptedEmbedder()
            settings = MeetingFixtures.isolatedSettings()
            settings.semanticSearchEnabled = enabled
            coordinator = SemanticIndexCoordinator(
                modelContext: context,
                appSettings: withSettings ? settings : nil,
                indexService: SemanticIndexService(embedder: embedder)
            )
        }

        func staleChunk(for meeting: Meeting, model: String = "stub-v0") {
            context.insert(SemanticChunk(
                meeting: meeting,
                recordingID: UUID(),
                text: "stale passage",
                startTime: 0,
                endTime: 1,
                speakerLabel: "Speaker 1",
                vector: [0, 1, 0],
                modelIdentifier: model
            ))
            try? context.save()
        }
    }

    // MARK: - Single meeting

    @Test func indexingStoresThePassagesWithTheEmbeddersModel() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)

        await harness.coordinator.index(meeting)

        #expect(meeting.semanticChunks.count == 1)
        #expect(meeting.semanticChunks.first?.modelIdentifier == "stub-v1")
        #expect(meeting.semanticChunks.first?.text.contains("we ship on monday") == true)
        #expect(harness.coordinator.indexedChunkCount() == 1)
        #expect(harness.coordinator.indexingMeetingIDs.isEmpty)
    }

    @Test func reindexingReplacesRatherThanAppends() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        harness.staleChunk(for: meeting)

        await harness.coordinator.index(meeting)

        #expect(meeting.semanticChunks.count == 1)
        #expect(meeting.semanticChunks.allSatisfy { $0.modelIdentifier == "stub-v1" })
    }

    @Test func aMeetingWithoutTranscriptLosesItsStaleChunks() async {
        let harness = Harness()
        let meeting = Meeting(title: "Empty")
        harness.context.insert(meeting)
        harness.staleChunk(for: meeting)

        await harness.coordinator.index(meeting)

        #expect(meeting.semanticChunks.isEmpty)
        #expect(harness.embedder.calls == 0)
    }

    @Test func anEmbedderFailureKeepsTheExistingIndex() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        harness.staleChunk(for: meeting)
        harness.embedder.fail(with: EmbedderDown())

        await harness.coordinator.index(meeting)

        #expect(meeting.semanticChunks.map(\.text) == ["stale passage"])
    }

    @Test func cancellationKeepsTheExistingIndex() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        harness.staleChunk(for: meeting)
        harness.embedder.fail(with: CancellationError())

        await harness.coordinator.index(meeting)

        #expect(meeting.semanticChunks.map(\.text) == ["stale passage"])
    }

    @Test func emptyVectorsLeaveTheIndexUntouched() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        harness.staleChunk(for: meeting)
        harness.embedder.returnEmptyVectors()

        await harness.coordinator.index(meeting)

        #expect(meeting.semanticChunks.map(\.text) == ["stale passage"])
    }

    // MARK: - Backfill / maintenance

    @Test func backfillIndexesMissingAndOutdatedMeetingsOnly() async {
        let harness = Harness()
        MeetingFixtures.transcribed("Missing", in: harness.context)
        let outdated = MeetingFixtures.transcribed("Outdated", in: harness.context)
        harness.staleChunk(for: outdated)
        let current = MeetingFixtures.transcribed("Current", in: harness.context)
        harness.staleChunk(for: current, model: "stub-v1")
        harness.context.insert(Meeting(title: "No transcript"))

        await harness.coordinator.backfill()

        #expect(harness.embedder.calls == 2)
        #expect(outdated.semanticChunks.allSatisfy { $0.modelIdentifier == "stub-v1" })
        #expect(current.semanticChunks.map(\.text) == ["stale passage"])
        #expect(!harness.coordinator.isBackfilling)
    }

    @Test func backfillDoesNothingWhenOffOrWithoutSettings() async {
        let disabled = Harness(enabled: false)
        MeetingFixtures.transcribed("Planning", in: disabled.context)
        await disabled.coordinator.backfill()

        let unset = Harness(withSettings: false)
        MeetingFixtures.transcribed("Planning", in: unset.context)
        await unset.coordinator.backfill()

        #expect(disabled.embedder.calls == 0)
        #expect(unset.embedder.calls == 0)
    }

    @Test func backfillWithNothingStaleEmbedsNothing() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        await harness.coordinator.index(meeting)

        await harness.coordinator.backfill()

        #expect(harness.embedder.calls == 1)
    }

    @Test func clearIndexDeletesEveryPassage() async {
        let harness = Harness()
        let meeting = MeetingFixtures.transcribed("Planning", in: harness.context)
        await harness.coordinator.index(meeting)

        harness.coordinator.clearIndex()

        #expect(harness.coordinator.indexedChunkCount() == 0)
    }

    @Test func rebuildReindexesEveryTranscribedMeetingEvenWhenDisabled() async {
        let harness = Harness(enabled: false)
        let first = MeetingFixtures.transcribed("First", in: harness.context)
        let second = MeetingFixtures.transcribed("Second", in: harness.context)
        harness.staleChunk(for: first, model: "stub-v1")
        harness.context.insert(Meeting(title: "No transcript"))

        await harness.coordinator.rebuild()

        #expect(harness.embedder.calls == 2)
        #expect(first.semanticChunks.count == 1)
        #expect(first.semanticChunks.first?.text != "stale passage")
        #expect(second.semanticChunks.count == 1)
    }
}

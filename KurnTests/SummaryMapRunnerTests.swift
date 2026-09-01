//
//  SummaryMapRunnerTests.swift
//  KurnTests
//
//  The map-stage runner behind staged summary/wiki generation: it must skip
//  already-condensed blocks when resuming, discard a resume whose identity
//  doesn't match exactly, and stop before the next block when a checkpoint
//  save fails (H4) — the summary-generation analogue of
//  ChunkedTranscriptionRunnerTests.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct SummaryMapRunnerTests {

    private let providerID = AIProvider.openAI.id
    private let model = "gpt-4o"

    @Test func condensesEveryBlockWithNoResume() async throws {
        let condensed = CondensedIndexes()
        let notes = try await SummaryMapRunner.run(
            blocks: ["block 0", "block 1", "block 2"],
            contentDigest: "digest",
            providerID: providerID,
            model: model,
            resume: nil,
            condenseBlock: { block, index in
                await condensed.record(index)
                return "notes for \(block)"
            }
        )

        #expect(await condensed.values == [0, 1, 2])
        #expect(notes == ["notes for block 0", "notes for block 1", "notes for block 2"])
    }

    @Test func resumeSkipsAlreadyCompletedBlocks() async throws {
        let condensed = CondensedIndexes()
        let resume = SummaryMapCheckpoint(
            contentDigest: "digest", providerID: providerID, model: model,
            totalBlocks: 3, completedNotes: ["earlier notes"]
        )

        let notes = try await SummaryMapRunner.run(
            blocks: ["block 0", "block 1", "block 2"],
            contentDigest: "digest",
            providerID: providerID,
            model: model,
            resume: resume,
            condenseBlock: { block, index in
                await condensed.record(index)
                return "notes for \(block)"
            }
        )

        // Only blocks 1 and 2 actually condensed; block 0's notes are reused.
        #expect(await condensed.values == [1, 2])
        #expect(notes == ["earlier notes", "notes for block 1", "notes for block 2"])
    }

    @Test func mismatchedContentDigestStartsOver() async throws {
        let condensed = CondensedIndexes()
        let resume = SummaryMapCheckpoint(
            contentDigest: "stale-digest", providerID: providerID, model: model,
            totalBlocks: 3, completedNotes: ["stale notes"]
        )

        let notes = try await SummaryMapRunner.run(
            blocks: ["block 0", "block 1", "block 2"],
            contentDigest: "fresh-digest",
            providerID: providerID,
            model: model,
            resume: resume,
            condenseBlock: { block, index in
                await condensed.record(index)
                return "notes for \(block)"
            }
        )

        #expect(await condensed.values == [0, 1, 2])
        #expect(notes == ["notes for block 0", "notes for block 1", "notes for block 2"])
    }

    @Test func mismatchedProviderStartsOverEvenWithTheSameContent() async throws {
        // Same content, same block count — but a different provider means
        // splicing notes from two vendors into one reduce pass, exactly the
        // quality-mixing bug H4 already closed for transcription checkpoints.
        let condensed = CondensedIndexes()
        let resume = SummaryMapCheckpoint(
            contentDigest: "digest", providerID: AIProvider.groq.id, model: model,
            totalBlocks: 3, completedNotes: ["groq notes"]
        )

        let notes = try await SummaryMapRunner.run(
            blocks: ["block 0", "block 1", "block 2"],
            contentDigest: "digest",
            providerID: providerID,
            model: model,
            resume: resume,
            condenseBlock: { block, index in
                await condensed.record(index)
                return "notes for \(block)"
            }
        )

        #expect(await condensed.values == [0, 1, 2])
        #expect(notes == ["notes for block 0", "notes for block 1", "notes for block 2"])
    }

    @Test func structurallyInvalidResumeIsIgnored() async throws {
        let condensed = CondensedIndexes()
        // More completed notes than the plan has blocks — never trusted.
        let resume = SummaryMapCheckpoint(
            contentDigest: "digest", providerID: providerID, model: model,
            totalBlocks: 1, completedNotes: ["a", "b", "c"]
        )

        _ = try await SummaryMapRunner.run(
            blocks: ["block 0"],
            contentDigest: "digest",
            providerID: providerID,
            model: model,
            resume: resume,
            condenseBlock: { _, index in
                await condensed.record(index)
                return "fresh notes"
            }
        )

        #expect(await condensed.values == [0])
    }

    @Test func fullyCompletedResumeCondensesNothing() async throws {
        let resume = SummaryMapCheckpoint(
            contentDigest: "digest", providerID: providerID, model: model,
            totalBlocks: 1, completedNotes: ["all done"]
        )

        let notes = try await SummaryMapRunner.run(
            blocks: ["block 0"],
            contentDigest: "digest",
            providerID: providerID,
            model: model,
            resume: resume,
            condenseBlock: { _, _ in
                Issue.record("should not condense any block")
                return "should not run"
            }
        )

        #expect(notes == ["all done"])
    }

    @Test func checkpointSaveFailureStopsTheRunBeforeTheNextBlock() async throws {
        // H4: block N+1 must not start until block N's notes are durably
        // committed. A throwing `onStageCompleted` must stop the loop at
        // block N and rethrow, rather than continuing with in-memory-only
        // progress.
        let condensed = CondensedIndexes()
        struct SimulatedSaveFailure: Error {}

        await #expect(throws: SimulatedSaveFailure.self) {
            _ = try await SummaryMapRunner.run(
                blocks: ["block 0", "block 1", "block 2"],
                contentDigest: "digest",
                providerID: providerID,
                model: model,
                resume: nil,
                condenseBlock: { block, index in
                    await condensed.record(index)
                    return "notes for \(block)"
                },
                onStageCompleted: { checkpoint in
                    if checkpoint.completedNotes.count == 1 {
                        throw SimulatedSaveFailure()
                    }
                }
            )
        }

        // Only the first block ran; the second and third never started.
        #expect(await condensed.values == [0])
    }

    @Test func reportsDurableProgressAfterEveryBlock() async throws {
        let snapshots = CheckpointSnapshots()

        _ = try await SummaryMapRunner.run(
            blocks: ["block 0", "block 1"],
            contentDigest: "digest",
            providerID: providerID,
            model: model,
            resume: nil,
            condenseBlock: { block, _ in "notes for \(block)" },
            onStageCompleted: { checkpoint in snapshots.record(checkpoint) }
        )

        let recorded = snapshots.values
        #expect(recorded.map(\.completedNotes.count) == [1, 2])
        #expect(recorded.allSatisfy { $0.totalBlocks == 2 && $0.contentDigest == "digest" })
    }
}

/// Order-preserving async-safe recorder for which block indexes condensed.
private actor CondensedIndexes {
    private(set) var values: [Int] = []
    func record(_ index: Int) { values.append(index) }
}

/// Synchronous, lock-protected recorder so the ordering of the runner's
/// `onStageCompleted` calls can be asserted exactly.
private final class CheckpointSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SummaryMapCheckpoint] = []

    var values: [SummaryMapCheckpoint] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ checkpoint: SummaryMapCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(checkpoint)
    }
}

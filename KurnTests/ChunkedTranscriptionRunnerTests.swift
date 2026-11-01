//
//  ChunkedTranscriptionRunnerTests.swift
//  KurnTests
//
//  The chunk runner is the shared loop behind the resumable engines: it must
//  offset chunk-local spans to the input timeline, skip already-completed
//  chunks when resuming, discard a resume whose plan doesn't match — by count
//  or by exact cut points — and report durable progress after every chunk.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ChunkedTranscriptionRunnerTests {

    private func chunks(_ offsets: [TimeInterval]) -> [AudioChunker.Chunk] {
        offsets.enumerated().map { index, offset in
            AudioChunker.Chunk(
                url: URL(fileURLWithPath: "/tmp/chunk_\(index).m4a"),
                offset: offset
            )
        }
    }

    private func planDigest(_ offsets: [TimeInterval]) -> String {
        PipelineDigest.sha256Hex(of: offsets)
    }

    @Test func offsetsChunkLocalSpansToInputTimeline() async throws {
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
            planDigest: planDigest([0, 600]),
            resume: nil,
            transcribeChunk: { _, index in
                RawTranscript(
                    spans: [TranscribedSpan(text: "chunk \(index)", start: 1, end: 2, confidence: nil)],
                    language: "en"
                )
            }
        )

        #expect(result.spans.count == 2)
        #expect(result.spans[0].start == 1)
        #expect(result.spans[1].start == 601)
        #expect(result.spans[1].end == 602)
        #expect(result.language == "en")
    }

    @Test func resumeSkipsCompletedChunks() async throws {
        let transcribedIndexes = TranscribedIndexes()
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 3,
            completedChunks: 2,
            detectedLanguage: "pt",
            planDigest: planDigest([0, 600, 1200]),
            spans: [
                TranscribedSpan(text: "earlier", start: 0, end: 1, confidence: nil),
                TranscribedSpan(text: "work", start: 600, end: 601, confidence: nil)
            ]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600, 1200]),
            planDigest: planDigest([0, 600, 1200]),
            resume: resume,
            transcribeChunk: { _, index in
                await transcribedIndexes.record(index)
                return RawTranscript(
                    spans: [TranscribedSpan(text: "new", start: 5, end: 6, confidence: nil)],
                    language: "en"
                )
            }
        )

        // Only the third chunk actually transcribed; earlier spans are reused
        // and the resumed language sticks.
        #expect(await transcribedIndexes.values == [2])
        #expect(result.spans.map(\.text) == ["earlier", "work", "new"])
        #expect(result.spans[2].start == 1205)
        #expect(result.language == "pt")
    }

    @Test func mismatchedResumePlanCountStartsOver() async throws {
        let transcribedIndexes = TranscribedIndexes()
        // Saved against a 5-chunk plan; the current plan has 2 chunks.
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 5,
            completedChunks: 3,
            detectedLanguage: "pt",
            planDigest: planDigest([0, 100, 200, 300, 400]),
            spans: [TranscribedSpan(text: "stale", start: 0, end: 1, confidence: nil)]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
            planDigest: planDigest([0, 600]),
            resume: resume,
            transcribeChunk: { _, index in
                await transcribedIndexes.record(index)
                return RawTranscript(spans: [], language: "en")
            }
        )

        #expect(await transcribedIndexes.values == [0, 1])
        #expect(result.spans.isEmpty)
        #expect(result.language == "en")
    }

    @Test func mismatchedResumePlanDigestStartsOverEvenWithSameChunkCount() async throws {
        // Same chunk *count* (2) as the current plan, but cut at different
        // offsets — e.g. VAD/compaction found different silence this time.
        // The old count-only check would have wrongly accepted this resume.
        let transcribedIndexes = TranscribedIndexes()
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 2,
            completedChunks: 1,
            detectedLanguage: "pt",
            planDigest: planDigest([0, 500]),
            spans: [TranscribedSpan(text: "stale", start: 0, end: 1, confidence: nil)]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
            planDigest: planDigest([0, 600]),
            resume: resume,
            transcribeChunk: { _, index in
                await transcribedIndexes.record(index)
                return RawTranscript(spans: [], language: "en")
            }
        )

        #expect(await transcribedIndexes.values == [0, 1])
        #expect(result.spans.isEmpty)
        #expect(result.language == "en")
    }

    @Test func reportsDurableProgressAfterEveryChunk() async throws {
        let snapshots = ProgressSnapshots()
        let progressSnapshots = ProgressFractionSnapshots()

        _ = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600, 1200]),
            planDigest: planDigest([0, 600, 1200]),
            resume: nil,
            transcribeChunk: { _, _ in
                RawTranscript(
                    spans: [TranscribedSpan(text: "x", start: 0, end: 1, confidence: nil)],
                    language: "en"
                )
            },
            onChunkCompleted: { progress in snapshots.record(progress) },
            onProgress: { progress, currentChunk, total in progressSnapshots.record(fraction: progress, currentChunk: currentChunk, total: total) }
        )

        let recorded = snapshots.values
        #expect(recorded.map(\.completedChunks) == [1, 2, 3])
        #expect(recorded.allSatisfy { $0.totalChunks == 3 })
        #expect(recorded.last?.spans.count == 3)

        let progressValues = progressSnapshots.values
        #expect(progressValues.map(\.fraction) == [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0])
        #expect(progressValues.map(\.currentChunk) == [1, 2, 3, 3])
        #expect(progressValues.allSatisfy { $0.total == 3 })
    }

    @Test func checkpointSaveFailureStopsTheRunBeforeTheNextChunk() async throws {
        // H4: chunk N+1 must not start until chunk N's checkpoint is durably
        // committed. A throwing `onChunkCompleted` (simulating a failed
        // SwiftData save) must stop the loop at chunk N and rethrow, rather
        // than continuing on with in-memory-only progress.
        let transcribedIndexes = TranscribedIndexes()
        struct SimulatedSaveFailure: Error {}

        await #expect(throws: SimulatedSaveFailure.self) {
            _ = try await ChunkedTranscriptionRunner.run(
                chunks: chunks([0, 600, 1200]),
                planDigest: planDigest([0, 600, 1200]),
                resume: nil,
                transcribeChunk: { _, index in
                    await transcribedIndexes.record(index)
                    return RawTranscript(
                        spans: [TranscribedSpan(text: "x", start: 0, end: 1, confidence: nil)],
                        language: "en"
                    )
                },
                onChunkCompleted: { progress in
                    if progress.completedChunks == 1 {
                        throw SimulatedSaveFailure()
                    }
                }
            )
        }

        // Only the first chunk ran; the second and third never started.
        #expect(await transcribedIndexes.values == [0])
    }

    // MARK: - Native diarization speaker turns

    @Test func speakerTurnsFromEachChunkAreAccumulatedAndOffsetToTheInputTimeline() async throws {
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
            planDigest: planDigest([0, 600]),
            resume: nil,
            transcribeChunk: { _, index in
                RawTranscript(
                    spans: [TranscribedSpan(text: "chunk \(index)", start: 0, end: 1, confidence: nil)],
                    language: "en",
                    speakerTurns: [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 1)]
                )
            }
        )

        let turns = try #require(result.speakerTurns)
        #expect(turns.count == 2)
        #expect(turns[0].start == 0)
        #expect(turns[0].end == 1)
        #expect(turns[1].start == 600)
        #expect(turns[1].end == 601)
    }

    /// A provider that never returns native diarization (Apple Speech,
    /// whisper-1, any non-diarizing route) must leave `speakerTurns` `nil`,
    /// not an empty array — `nil` is what tells `TranscriptionService` this
    /// engine didn't attempt native diarization at all, as opposed to a
    /// diarizing provider that genuinely found zero turns.
    @Test func speakerTurnsStaysNilWhenNoChunkReturnsAny() async throws {
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
            planDigest: planDigest([0, 600]),
            resume: nil,
            transcribeChunk: { _, _ in
                RawTranscript(spans: [], language: "en")
            }
        )

        #expect(result.speakerTurns == nil)
    }

    /// Documented trade-off: speaker turns are not part of the persisted
    /// `Progress` checkpoint, so a resumed run only carries native
    /// diarization for chunks it actually re-transcribes — turns from a
    /// prior interrupted run's already-completed chunks are not recovered.
    @Test func resumeOnlyCarriesSpeakerTurnsFromChunksItActuallyRetranscribes() async throws {
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 2,
            completedChunks: 1,
            detectedLanguage: "en",
            planDigest: planDigest([0, 600]),
            spans: [TranscribedSpan(text: "earlier", start: 0, end: 1, confidence: nil)]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
            planDigest: planDigest([0, 600]),
            resume: resume,
            transcribeChunk: { _, index in
                RawTranscript(
                    spans: [TranscribedSpan(text: "new", start: 0, end: 1, confidence: nil)],
                    language: "en",
                    speakerTurns: [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 1)]
                )
            }
        )

        let turns = try #require(result.speakerTurns)
        // Only chunk 1 (the resumed-past chunk 0 contributes nothing).
        #expect(turns.count == 1)
        #expect(turns[0].start == 600)
    }

}

extension ChunkedTranscriptionRunnerTests {

    private func expectIntegrityFailure(
        _ expectedReason: TranscriptIntegrityFailure,
        operation: () async throws -> RawTranscript
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected a localized transcript integrity failure")
        } catch AppError.transcriptIntegrityFailed(let reason) {
            #expect(reason == expectedReason.rawValue)
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }

    private func boundedChunks() -> [AudioChunker.Chunk] {
        [0.0, 10.0].enumerated().map { index, offset in
            AudioChunker.Chunk(url: URL(fileURLWithPath: "/tmp/bounded_\(index).m4a"), offset: offset, duration: 10)
        }
    }

    @Test func normalizesSpansAndNativeTurnsBeforeOffsetsAndCheckpointing() async throws {
        let snapshots = ProgressSnapshots()
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: boundedChunks(),
            planDigest: planDigest([0, 10]),
            resume: nil,
            transcribeChunk: { _, _ in
                RawTranscript(spans: [
                    TranscribedSpan(text: " tail! ", start: 9.8, end: 40, confidence: 0.7),
                    TranscribedSpan(text: "earlier", start: -0.05, end: 1, confidence: nil),
                    TranscribedSpan(text: "tiny", start: 2.04, end: 2, confidence: 0.9)
                ], language: "pt-BR", speakerTurns: [SpeakerTurn(speakerLabel: "host", start: -0.1, end: 13.5)])
            },
            onChunkCompleted: { snapshots.record($0) }
        )
        #expect(result.spans.map(\.text) == [" tail! ", "earlier", "tiny", " tail! ", "earlier", "tiny"])
        #expect(result.spans.map(\.confidence) == [0.7, nil, 0.9, 0.7, nil, 0.9])
        #expect(result.spans.map(\.start) == [9.8, 0, 2.04, 19.8, 10, 12.04])
        #expect(result.spans.map(\.end) == [10, 1, 2.04, 20, 11, 12.04])
        #expect(result.speakerTurns == [
            SpeakerTurn(speakerLabel: "host", start: 0, end: 10),
            SpeakerTurn(speakerLabel: "host", start: 10, end: 20)
        ])
        #expect(result.language == "pt-BR")
        #expect(snapshots.values[0].spans.map(\.end) == [10, 1, 2.04])
        #expect(snapshots.values.last?.spans == result.spans)
    }

    @Test(arguments: [false, true])
    func invalidChunkIsNeverCheckpointedAndStopsBeforeTheNextRequest(nativeTurn: Bool) async throws {
        let indexes = TranscribedIndexes()
        let snapshots = ProgressSnapshots()
        await expectIntegrityFailure(.segmentOutOfBounds) {
            try await ChunkedTranscriptionRunner.run(
                chunks: boundedChunks(),
                planDigest: planDigest([0, 10]),
                resume: nil,
                transcribeChunk: { _, index in
                    await indexes.record(index)
                    return RawTranscript(
                        spans: [TranscribedSpan(text: "keep", start: 0, end: nativeTurn ? 1 : 40.01)],
                        language: "en",
                        speakerTurns: nativeTurn ? [SpeakerTurn(speakerLabel: "bad", start: 0, end: 40.01)] : nil
                    )
                },
                onChunkCompleted: { snapshots.record($0) }
            )
        }
        #expect(await indexes.values == [0])
        #expect(snapshots.values.isEmpty)
    }

    @Test func invalidLaterChunkLeavesOnlyTheEarlierDurableCheckpoint() async throws {
        let indexes = TranscribedIndexes()
        let snapshots = ProgressSnapshots()
        let plan = [0.0, 10.0, 20.0].enumerated().map { index, offset in
            AudioChunker.Chunk(url: URL(fileURLWithPath: "/tmp/later_\(index).m4a"), offset: offset, duration: 10)
        }
        await expectIntegrityFailure(.segmentOutOfBounds) {
            try await ChunkedTranscriptionRunner.run(
                chunks: plan, planDigest: planDigest([0, 10, 20]), resume: nil,
                transcribeChunk: { _, index in
                    await indexes.record(index)
                    return RawTranscript(spans: [TranscribedSpan(text: "word", start: 0, end: index == 1 ? .nan : 1)], language: "en")
                },
                onChunkCompleted: { snapshots.record($0) }
            )
        }
        #expect(await indexes.values == [0, 1])
        #expect(snapshots.values.map(\.completedChunks) == [1])
        #expect(snapshots.values[0].spans == [TranscribedSpan(text: "word", start: 0, end: 1)])
    }

    @Test func zeroDurationKeepsSpeechButDoesNotInventTime() async throws {
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: [AudioChunker.Chunk(url: URL(fileURLWithPath: "/tmp/zero.m4a"), offset: 0, duration: 0)],
            planDigest: planDigest([0]), resume: nil,
            transcribeChunk: { _, _ in
                RawTranscript(spans: [TranscribedSpan(text: "keep", start: -0.1, end: 0.2, confidence: 0.5)], language: "en")
            }
        )
        #expect(result.spans == [TranscribedSpan(text: "keep", start: 0, end: 0, confidence: 0.5)])
    }

    @Test func invalidKnownDurationFailsBeforeTheRequest() async throws {
        let indexes = TranscribedIndexes()
        let snapshots = ProgressSnapshots()
        await expectIntegrityFailure(.sourceUnreadable) {
            try await ChunkedTranscriptionRunner.run(
                chunks: [AudioChunker.Chunk(url: URL(fileURLWithPath: "/tmp/invalid.m4a"), offset: 0, duration: .nan)],
                planDigest: planDigest([0]), resume: nil,
                transcribeChunk: { _, index in
                    await indexes.record(index)
                    return RawTranscript(spans: [], language: "en")
                },
                onChunkCompleted: { snapshots.record($0) }
            )
        }
        #expect(await indexes.values.isEmpty)
        #expect(snapshots.values.isEmpty)
    }

    @Test func completedResumeNormalizesLegacyBoundaryDriftWithoutNetwork() async throws {
        let spans = [
            TranscribedSpan(text: "first", start: -0.04, end: 10.3, confidence: 0.6),
            TranscribedSpan(text: "last", start: 19.6, end: 50, confidence: nil),
            TranscribedSpan(text: "reordered", start: 10.5, end: 11, confidence: 0.8)
        ]
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 2, completedChunks: 2, detectedLanguage: "pt", planDigest: planDigest([0, 10]), spans: spans
        )
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: boundedChunks(), planDigest: planDigest([0, 10]), resume: resume,
            transcribeChunk: { _, _ in
                Issue.record("completed checkpoint must not use the network")
                return RawTranscript(spans: [], language: "")
            }
        )
        #expect(result.spans.map(\.text) == spans.map(\.text))
        #expect(result.spans.map(\.confidence) == spans.map(\.confidence))
        #expect(result.spans.map(\.start) == [0, 19.6, 10.5])
        #expect(result.spans.map(\.end) == [10, 20, 11])
        #expect(result.language == "pt")
    }

    @Test(arguments: [0, 1, 2])
    func unusableResumeRestartsAndRewritesDurableCheckpoint(completedChunks: Int) async throws {
        let indexes = TranscribedIndexes()
        let snapshots = ProgressSnapshots()
        let progress = ProgressFractionSnapshots()
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 2, completedChunks: completedChunks, detectedLanguage: "stale", planDigest: planDigest([0, 10]),
            spans: [TranscribedSpan(text: "bad", start: 0, end: 100)]
        )
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: boundedChunks(), planDigest: planDigest([0, 10]), resume: resume,
            transcribeChunk: { _, index in
                await indexes.record(index)
                return RawTranscript(spans: [
                    TranscribedSpan(text: "late\(index)", start: 4, end: 5, confidence: 0.7),
                    TranscribedSpan(text: "early\(index)", start: 1, end: 2)
                ], language: "pt")
            },
            onChunkCompleted: { snapshots.record($0) },
            onProgress: { fraction, current, total in progress.record(fraction: fraction, currentChunk: current, total: total) }
        )
        #expect(await indexes.values == [0, 1])
        #expect(progress.values.first?.fraction == 0)
        #expect(result.spans.map(\.text) == ["late0", "early0", "late1", "early1"])
        #expect(result.spans.map(\.start) == [4, 1, 14, 11])
        #expect(result.language == "pt")
        #expect(snapshots.values.map(\.completedChunks) == [1, 2])
        #expect(snapshots.values.allSatisfy { $0.detectedLanguage == "pt" })
        #expect(snapshots.values[0].spans == Array(result.spans.prefix(2)))
        #expect(snapshots.values.last?.spans == result.spans)
    }

    @Test func resumedSpansAreNormalizedInTheNextDurableCheckpoint() async throws {
        let snapshots = ProgressSnapshots()
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 2, completedChunks: 1, detectedLanguage: "pt", planDigest: planDigest([0, 10]),
            spans: [TranscribedSpan(text: "saved", start: 9.8, end: 10.4, confidence: 0.5)]
        )
        _ = try await ChunkedTranscriptionRunner.run(
            chunks: boundedChunks(), planDigest: planDigest([0, 10]), resume: resume,
            transcribeChunk: { _, index in
                #expect(index == 1)
                return RawTranscript(spans: [TranscribedSpan(text: "new", start: 0, end: 1)], language: "en")
            },
            onChunkCompleted: { snapshots.record($0) }
        )
        #expect(snapshots.values.count == 1)
        #expect(snapshots.values[0].spans.map(\.end) == [10, 11])
        #expect(snapshots.values[0].detectedLanguage == "pt")
    }

    @Test func invalidPlanMapsToIntegrityFailureBeforeAnyRequestOrCheckpoint() async throws {
        let indexes = TranscribedIndexes()
        let snapshots = ProgressSnapshots()
        let plan = [10.0, 0.0].map { offset in
            AudioChunker.Chunk(url: URL(fileURLWithPath: "/tmp/plan.m4a"), offset: offset, duration: 10)
        }
        await expectIntegrityFailure(.segmentOutOfBounds) {
            try await ChunkedTranscriptionRunner.run(
                chunks: plan, planDigest: planDigest([10, 0]), resume: nil,
                transcribeChunk: { _, index in
                    await indexes.record(index)
                    return RawTranscript(spans: [], language: "en")
                },
                onChunkCompleted: { snapshots.record($0) }
            )
        }
        #expect(await indexes.values.isEmpty)
        #expect(snapshots.values.isEmpty)
    }

    @Test(arguments: [false, true])
    func providerFailuresAndCancellationAreNotWrapped(cancellation: Bool) async throws {
        struct ProviderFailure: Error {}
        let indexes = TranscribedIndexes()
        let snapshots = ProgressSnapshots()
        let operation = {
            try await ChunkedTranscriptionRunner.run(
                chunks: boundedChunks(), planDigest: planDigest([0, 10]), resume: nil,
                transcribeChunk: { _, index in
                    await indexes.record(index)
                    if cancellation { throw CancellationError() }
                    throw ProviderFailure()
                },
                onChunkCompleted: { snapshots.record($0) }
            )
        }
        if cancellation {
            await #expect(throws: CancellationError.self) { try await operation() }
        } else {
            await #expect(throws: ProviderFailure.self) { try await operation() }
        }
        #expect(await indexes.values == [0])
        #expect(snapshots.values.isEmpty)
    }

    @Test func completedResumeTranscribesNothing() async throws {
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 1,
            completedChunks: 1,
            detectedLanguage: "en",
            planDigest: planDigest([0]),
            spans: [TranscribedSpan(text: "all done", start: 0, end: 1, confidence: nil)]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0]),
            planDigest: planDigest([0]),
            resume: resume,
            transcribeChunk: { _, _ in
                Issue.record("should not transcribe any chunk")
                return RawTranscript(spans: [], language: "")
            }
        )

        #expect(result.spans.map(\.text) == ["all done"])
    }
}

/// Order-preserving async-safe recorder for which chunk indexes transcribed.
private actor TranscribedIndexes {
    private(set) var values: [Int] = []
    func record(_ index: Int) { values.append(index) }
}

/// Synchronous, lock-protected recorder so the ordering of the runner's
/// `onChunkCompleted` calls can be asserted exactly.
private final class ProgressSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ChunkedTranscriptionRunner.Progress] = []

    var values: [ChunkedTranscriptionRunner.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ progress: ChunkedTranscriptionRunner.Progress) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(progress)
    }
}

/// Synchronous recorder for the chunk-aware `onProgress` values.
private final class ProgressFractionSnapshots: @unchecked Sendable {
    struct Snapshot: Sendable {
        let fraction: Double
        let currentChunk: Int
        let total: Int
    }

    private let lock = NSLock()
    private var storage: [Snapshot] = []

    var values: [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(fraction: Double, currentChunk: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Snapshot(fraction: fraction, currentChunk: currentChunk, total: total))
    }
}

//
//  ChunkedTranscriptionRunnerTests.swift
//  KurnTests
//
//  The chunk runner is the shared loop behind the resumable engines: it must
//  offset chunk-local spans to the input timeline, skip already-completed
//  chunks when resuming, discard a resume whose plan doesn't match, and report
//  durable progress after every chunk.
//

import Foundation
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

    @Test func offsetsChunkLocalSpansToInputTimeline() async throws {
        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
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
            spans: [
                TranscribedSpan(text: "earlier", start: 0, end: 1, confidence: nil),
                TranscribedSpan(text: "work", start: 600, end: 601, confidence: nil)
            ]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600, 1200]),
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

    @Test func mismatchedResumePlanStartsOver() async throws {
        let transcribedIndexes = TranscribedIndexes()
        // Saved against a 5-chunk plan; the current plan has 2 chunks.
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 5,
            completedChunks: 3,
            detectedLanguage: "pt",
            spans: [TranscribedSpan(text: "stale", start: 0, end: 1, confidence: nil)]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600]),
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

        _ = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0, 600, 1200]),
            resume: nil,
            transcribeChunk: { _, _ in
                RawTranscript(
                    spans: [TranscribedSpan(text: "x", start: 0, end: 1, confidence: nil)],
                    language: "en"
                )
            },
            onChunkCompleted: { progress in snapshots.record(progress) }
        )

        let recorded = snapshots.values
        #expect(recorded.map(\.completedChunks) == [1, 2, 3])
        #expect(recorded.allSatisfy { $0.totalChunks == 3 })
        #expect(recorded.last?.spans.count == 3)
    }

    @Test func completedResumeTranscribesNothing() async throws {
        let resume = ChunkedTranscriptionRunner.Progress(
            totalChunks: 1,
            completedChunks: 1,
            detectedLanguage: "en",
            spans: [TranscribedSpan(text: "all done", start: 0, end: 1, confidence: nil)]
        )

        let result = try await ChunkedTranscriptionRunner.run(
            chunks: chunks([0]),
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

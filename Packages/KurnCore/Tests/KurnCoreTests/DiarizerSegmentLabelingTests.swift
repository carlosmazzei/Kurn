//
//  DiarizerSegmentLabelingTests.swift
//  KurnCoreTests
//
//  The neural diarizer's ids become "Speaker N" in order of first appearance,
//  progress reports only when the percentage moves, and `withTimeout` returns
//  the operation's result or the caller's error.
//

import Foundation
import Testing
@testable import KurnCore

struct DiarizerSegmentLabelingTests {

    @Test func labelsFollowFirstAppearanceInTimeNotInput() {
        let turns = DiarizerSegmentLabeling.turns(from: [
            DiarizerSegment(speakerID: "b", start: 5, end: 6),
            DiarizerSegment(speakerID: "a", start: 0, end: 2),
            DiarizerSegment(speakerID: "b", start: 2, end: 4),
            DiarizerSegment(speakerID: "c", start: 7, end: 8)
        ])
        #expect(turns == [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 2),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 2, end: 4),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 5, end: 6),
            SpeakerTurn(speakerLabel: "Speaker 3", start: 7, end: 8)
        ])
    }

    @Test func emptyInputGivesNoTurns() {
        #expect(DiarizerSegmentLabeling.turns(from: []).isEmpty)
        #expect(DiarizerSegmentLabeling.distinctSpeakerCount(in: []) == 0)
    }

    @Test func distinctSpeakersCountIDs() {
        let segments = [
            DiarizerSegment(speakerID: "x", start: 0, end: 1),
            DiarizerSegment(speakerID: "x", start: 1, end: 2)
        ]
        #expect(DiarizerSegmentLabeling.distinctSpeakerCount(in: segments) == 1)
    }

    @Test func progressReportsOnlyWhenThePercentMoves() {
        // 300 chunks: chunk 1 is 0% → not a new percent, but logged as the first.
        let first = ChunkProgressSampler.step(processed: 1, total: 300, elapsed: 3)
        #expect(first.fraction == nil)
        #expect(first.shouldLog)
        #expect(first.estimatedRemaining == 897)

        let third = ChunkProgressSampler.step(processed: 3, total: 300, elapsed: 9)
        #expect(third.fraction == 0.01)
        #expect(!third.shouldLog)

        let decile = ChunkProgressSampler.step(processed: 30, total: 300, elapsed: 90)
        #expect(decile.percent == 10)
        #expect(decile.shouldLog)

        let last = ChunkProgressSampler.step(processed: 300, total: 300, elapsed: 900)
        #expect(last.isFinished)
        #expect(last.fraction == 1)
        #expect(last.estimatedRemaining == 0)
    }

    @Test func progressClampsNonsenseInput() {
        let none = ChunkProgressSampler.step(processed: 0, total: 0, elapsed: 5)
        #expect(none.estimatedRemaining == 0)
        #expect(none.percent == 0)
        let over = ChunkProgressSampler.step(processed: 9, total: 4, elapsed: 1)
        #expect(over.isFinished)
    }

    private struct Deadline: Error {}

    @Test func timeoutReturnsTheResultWhenItFinishesFirst() async throws {
        let value = try await withTimeout(seconds: 5, timeoutError: { Deadline() }) { 42 }
        #expect(value == 42)
    }

    @Test func timeoutThrowsTheCallersErrorWhenTheDeadlineWins() async {
        await #expect(throws: Deadline.self) {
            try await withTimeout(seconds: 0.01, timeoutError: { Deadline() }) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
    }

    @Test func operationErrorsPassThrough() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withTimeout(seconds: 5, timeoutError: { Deadline() }) { () async throws -> Int in throw Boom() }
        }
    }
}

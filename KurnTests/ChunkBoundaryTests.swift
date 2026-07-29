//
//  ChunkBoundaryTests.swift
//  KurnTests
//
//  Where a chunk ends.
//
//  The property that matters most here is not "it finds the silence" — it is
//  that the plan is *reproducible*. A resumed transcription only reuses its
//  checkpoint when the chunk plan comes out identical; a boundary that moved
//  between runs would throw away every completed chunk without saying so.
//

import Foundation
import Testing
@testable import Kurn

struct ChunkBoundaryTests {

    private let tolerance = ChunkBoundary.tolerance

    @Test func snapsToTheNearestSilenceInsideTheWindow() {
        let end = ChunkBoundary.end(
            start: 0,
            nominalEnd: 600,
            total: 1800,
            candidates: [120, 595, 610, 900]
        )
        // 595 and 610 are both in the window; 610 is 10s away, 595 is 5s.
        #expect(end == 595)
    }

    @Test func keepsTheNominalBoundaryWhenNoSilenceIsNear() {
        let end = ChunkBoundary.end(
            start: 0,
            nominalEnd: 600,
            total: 1800,
            candidates: [120, 900]
        )
        #expect(end == 600)
    }

    @Test func noCandidatesAtAllBehavesAsBefore() {
        #expect(
            ChunkBoundary.end(start: 0, nominalEnd: 600, total: 1800, candidates: []) == 600
        )
    }

    /// The last chunk ends where the audio ends. Snapping it would leave the
    /// tail of the recording untranscribed.
    @Test func theFinalChunkIsNeverMoved() {
        let end = ChunkBoundary.end(
            start: 1200,
            nominalEnd: 1500,
            total: 1500,
            candidates: [1480, 1490]
        )
        #expect(end == 1500)
    }

    /// A silence 5 s into a chunk is inside the tolerance of a *short* nominal
    /// chunk, and taking it would produce a sliver with a whole request's
    /// overhead attached.
    @Test func neverProducesAChunkShorterThanTheMinimum() {
        let end = ChunkBoundary.end(
            start: 1000,
            nominalEnd: 1010,
            total: 5000,
            candidates: [1005],
            tolerance: 30
        )
        #expect(end - 1000 >= ChunkBoundary.minimumDuration || end == 1010)
    }

    @Test func staysWithinTheTolerance() {
        let end = ChunkBoundary.end(
            start: 0,
            nominalEnd: 600,
            total: 1800,
            candidates: [400, 800]
        )
        #expect(abs(end - 600) <= tolerance)
    }

    @Test func isDeterministicForTheSameInput() {
        let candidates: [TimeInterval] = [580, 590, 610, 620]
        let first = ChunkBoundary.end(start: 0, nominalEnd: 600, total: 1800, candidates: candidates)
        let again = ChunkBoundary.end(start: 0, nominalEnd: 600, total: 1800, candidates: candidates)
        #expect(first == again)
        // Ties resolve to the earlier candidate, since the list is sorted.
        #expect(first == 590)
    }

    // MARK: - Deriving the candidates

    @Test func cutPointsFallInTheMiddleOfEachSilence() {
        let regions = [
            SpeechRegion(start: 0, end: 10),
            SpeechRegion(start: 14, end: 20),
            SpeechRegion(start: 20, end: 30)
        ]
        // 10…14 has a midpoint; 20…20 is not a silence at all.
        #expect(ChunkBoundary.cutPoints(betweenSpeechRegions: regions) == [12])
    }

    @Test func oneRegionOffersNoCutPoints() {
        #expect(ChunkBoundary.cutPoints(betweenSpeechRegions: [SpeechRegion(start: 0, end: 10)]).isEmpty)
        #expect(ChunkBoundary.cutPoints(betweenSpeechRegions: []).isEmpty)
    }

    /// After compaction the engine sees a different timeline, and the only
    /// silence left in it is the gap the compactor writes before each region.
    @Test func compactedCutPointsAreTheRegionStarts() {
        let map = [
            TimelineSegment(compactedStart: 0, originalStart: 0, duration: 10),
            TimelineSegment(compactedStart: 10.1, originalStart: 30, duration: 5),
            TimelineSegment(compactedStart: 15.2, originalStart: 90, duration: 8)
        ]
        #expect(ChunkBoundary.cutPoints(inCompactedTimeline: map) == [10.1, 15.2])
    }
}

//
//  SpeakerTurnSmoothingTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct SpeakerTurnSmoothingTests {

    private static func turn(_ label: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(speakerLabel: label, start: start, end: end)
    }

    // MARK: - Merging

    @Test func adjacentSameSpeakerTurnsMergeAcrossShortGap() {
        let turns = [
            Self.turn("Speaker 1", 0, 4),
            Self.turn("Speaker 1", 4.3, 8)
        ]
        let merged = SpeakerTurnSmoothing.mergeAdjacent(turns, maxGap: 0.75)
        #expect(merged.count == 1)
        #expect(merged[0].start == 0)
        #expect(merged[0].end == 8)
    }

    @Test func sameSpeakerTurnsSeparatedByALongGapStaySeparate() {
        let turns = [
            Self.turn("Speaker 1", 0, 4),
            Self.turn("Speaker 1", 20, 24)
        ]
        #expect(SpeakerTurnSmoothing.mergeAdjacent(turns, maxGap: 0.75).count == 2)
    }

    @Test func differentSpeakersNeverMerge() {
        let turns = [
            Self.turn("Speaker 1", 0, 4),
            Self.turn("Speaker 2", 4, 8)
        ]
        #expect(SpeakerTurnSmoothing.mergeAdjacent(turns, maxGap: 5).count == 2)
    }

    @Test func overlappingSameSpeakerTurnsMergeToTheOuterBounds() {
        let turns = [
            Self.turn("Speaker 1", 0, 6),
            Self.turn("Speaker 1", 2, 4)
        ]
        let merged = SpeakerTurnSmoothing.mergeAdjacent(turns, maxGap: 0)
        #expect(merged.count == 1)
        #expect(merged[0].end == 6)
    }

    // MARK: - Short-turn absorption

    @Test func midSentenceFlipIsAbsorbedByTheSurroundingSpeaker() {
        // The classic neural-diarizer artifact: one speaker's sentence broken by
        // a 0.2s sliver assigned to someone else.
        let turns = [
            Self.turn("Speaker 1", 0, 10),
            Self.turn("Speaker 2", 10, 10.2),
            Self.turn("Speaker 1", 10.2, 20)
        ]
        let smoothed = SpeakerTurnSmoothing.smooth(turns)
        #expect(smoothed.count == 1)
        #expect(smoothed[0].speakerLabel == "Speaker 1")
        #expect(smoothed[0].start == 0)
        #expect(smoothed[0].end == 20)
    }

    @Test func shortTurnGoesToTheCloserNeighbourWhenTheyDiffer() {
        let turns = [
            Self.turn("Speaker 1", 0, 10),
            Self.turn("Speaker 3", 10.1, 10.3),
            Self.turn("Speaker 2", 15, 25)
        ]
        let absorbed = SpeakerTurnSmoothing.absorbShortTurns(turns, minDuration: 0.7)
        #expect(absorbed.count == 2)
        #expect(absorbed[0].speakerLabel == "Speaker 1")
        // Speaker 1 takes over the sliver's span, keeping the timeline covered.
        #expect(absorbed[0].end == 10.3)
    }

    @Test func absorptionIsSkippedWhenEveryTurnIsShort() {
        // A genuinely rapid exchange, not noise — dropping it all would leave
        // fusion with nothing to attribute against.
        let turns = [
            Self.turn("Speaker 1", 0, 0.4),
            Self.turn("Speaker 2", 0.4, 0.8),
            Self.turn("Speaker 1", 0.8, 1.2)
        ]
        #expect(SpeakerTurnSmoothing.absorbShortTurns(turns, minDuration: 0.7) == turns)
    }

    // MARK: - Marginal speakers

    @Test func phantomSpeakerWithNegligibleSpeechIsDropped() {
        let turns = [
            Self.turn("Speaker 1", 0, 60),
            Self.turn("Speaker 2", 60, 120),
            Self.turn("Speaker 3", 120, 121),
            Self.turn("Speaker 1", 121, 180)
        ]
        let kept = SpeakerTurnSmoothing.dropMarginalSpeakers(turns, minTotalDuration: 3)
        #expect(Set(kept.map(\.speakerLabel)) == ["Speaker 1", "Speaker 2"])
    }

    @Test func marginalSpeakersAreKeptWhenOnlyTwoSpeakersExist() {
        // With two speakers there is nothing to fold a dropped one into, and a
        // brief second voice is still a second voice.
        let turns = [
            Self.turn("Speaker 1", 0, 60),
            Self.turn("Speaker 2", 60, 60.5)
        ]
        #expect(SpeakerTurnSmoothing.dropMarginalSpeakers(turns, minTotalDuration: 3) == turns)
    }

    @Test func allSpeakersBelowTheFloorAreAllKept() {
        let turns = [
            Self.turn("Speaker 1", 0, 1),
            Self.turn("Speaker 2", 1, 2),
            Self.turn("Speaker 3", 2, 3)
        ]
        #expect(SpeakerTurnSmoothing.dropMarginalSpeakers(turns, minTotalDuration: 30) == turns)
    }

    // MARK: - Renumbering

    @Test func labelsAreRenumberedInFirstAppearanceOrder() {
        let turns = [
            Self.turn("Speaker 5", 0, 5),
            Self.turn("Speaker 2", 5, 10),
            Self.turn("Speaker 5", 10, 15)
        ]
        let renumbered = SpeakerTurnSmoothing.renumber(turns)
        #expect(renumbered.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    // MARK: - End to end

    @Test func smoothingNeverEmptiesANonEmptyInput() {
        let turns = [
            Self.turn("Speaker 1", 0, 0.1),
            Self.turn("Speaker 2", 0.1, 0.2)
        ]
        #expect(!SpeakerTurnSmoothing.smooth(turns).isEmpty)
    }

    @Test func singleTurnPassesThroughUnchanged() {
        let turns = [Self.turn("Speaker 1", 0, 30)]
        #expect(SpeakerTurnSmoothing.smooth(turns) == turns)
    }

    @Test func aCleanTwoSpeakerConversationSurvivesIntact() {
        let turns = [
            Self.turn("Speaker 1", 0, 12),
            Self.turn("Speaker 2", 12.5, 25),
            Self.turn("Speaker 1", 25.5, 40)
        ]
        let smoothed = SpeakerTurnSmoothing.smooth(turns)
        #expect(smoothed.count == 3)
        #expect(smoothed.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(smoothed.map(\.start) == [0, 12.5, 25.5])
    }

    @Test func smoothingIsIdempotent() {
        let turns = [
            Self.turn("Speaker 1", 0, 10),
            Self.turn("Speaker 2", 10, 10.2),
            Self.turn("Speaker 1", 10.2, 20),
            Self.turn("Speaker 2", 20.4, 35)
        ]
        let once = SpeakerTurnSmoothing.smooth(turns)
        #expect(SpeakerTurnSmoothing.smooth(once) == once)
    }
}

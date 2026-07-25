//
//  TranscriptFusionTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct TranscriptFusionTests {

    // MARK: - Speaker attribution

    @Test func spanInsideTurnGetsThatSpeaker() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 5),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 5, end: 10)
        ]
        let span = TranscribedSpan(text: "hi", start: 6, end: 7, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: span, in: turns) == "Speaker 2")
    }

    @Test func spanBetweenTurnsPicksNearestByDistance() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 4),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 10, end: 14)
        ]
        // Midpoint 5.0 → 1.0s from S1's end, 5.0s from S2's start → S1.
        let nearFirst = TranscribedSpan(text: "x", start: 4.5, end: 5.5, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: nearFirst, in: turns) == "Speaker 1")
        // Midpoint 9.0 → 5.0s from S1's end, 1.0s from S2's start → S2.
        let nearSecond = TranscribedSpan(text: "x", start: 8.5, end: 9.5, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: nearSecond, in: turns) == "Speaker 2")
    }

    @Test func spanStraddlingAHandoverGoesToTheSpeakerHoldingMostOfIt() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 10, end: 20)
        ]
        // 2.0s with Speaker 1 against 0.5s with Speaker 2, then the mirror case.
        let mostlyFirst = TranscribedSpan(text: "x", start: 8.0, end: 10.5, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: mostlyFirst, in: turns) == "Speaker 1")
        let mostlySecond = TranscribedSpan(text: "x", start: 9.5, end: 12.0, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: mostlySecond, in: turns) == "Speaker 2")
    }

    @Test func aSliverTurnUnderTheMidpointDoesNotStealTheSpan() {
        // The failure a midpoint test produces: a 0.2s turn happens to contain
        // the span's midpoint and takes the whole utterance with it.
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 4.9),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 4.9, end: 5.1),
            SpeakerTurn(speakerLabel: "Speaker 1", start: 5.1, end: 10)
        ]
        let span = TranscribedSpan(text: "a whole sentence", start: 0, end: 10, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: span, in: turns) == "Speaker 1")
    }

    @Test func spanOverlappingNothingStillFallsBackToNearest() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 4),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 30, end: 40)
        ]
        let span = TranscribedSpan(text: "x", start: 28, end: 29, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: span, in: turns) == "Speaker 2")
    }

    @Test func emptyTurnsFallBackToSpeakerOne() {
        let span = TranscribedSpan(text: "hi", start: 0, end: 1, confidence: nil)
        #expect(TranscriptFusion.speakerLabel(for: span, in: []) == "Speaker 1")
    }

    // MARK: - Segment merging

    @Test func consecutiveSameSpeakerSpansMergeIntoOneSegment() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10)]
        let spans = [
            TranscribedSpan(text: "hello", start: 0, end: 1, confidence: nil),
            TranscribedSpan(text: "there", start: 1, end: 2, confidence: nil)
        ]
        let segments = TranscriptFusion.segments(spans: spans, turns: turns)
        #expect(segments.count == 1)
        #expect(segments.first?.text == "hello there")
        #expect(segments.first?.startTime == 0)
        #expect(segments.first?.endTime == 2)
    }

    @Test func speakerChangeStartsNewSegment() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 2),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 2, end: 4)
        ]
        let spans = [
            TranscribedSpan(text: "one", start: 0, end: 1, confidence: nil),
            TranscribedSpan(text: "two", start: 2.5, end: 3.5, confidence: nil)
        ]
        let segments = TranscriptFusion.segments(spans: spans, turns: turns)
        #expect(segments.map(\.speakerLabel) == ["Speaker 1", "Speaker 2"])
        #expect(segments.map(\.text) == ["one", "two"])
    }

    @Test func runExceedingMaxDurationSplits() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 100)]
        // Three contiguous 15s spans of the same speaker. The cap keeps a segment
        // from exceeding 30s of spoken time (span.end - currentStart): "a" and "b"
        // merge (end 30 - start 0 == 30, not over), then "c" starts a new segment
        // (end 45 - start 0 > 30).
        let spans = [
            TranscribedSpan(text: "a", start: 0, end: 15, confidence: nil),
            TranscribedSpan(text: "b", start: 15, end: 30, confidence: nil),
            TranscribedSpan(text: "c", start: 30, end: 45, confidence: nil)
        ]
        let segments = TranscriptFusion.segments(spans: spans, turns: turns, maxSegmentDuration: 30)
        #expect(segments.count == 2)
        #expect(segments.first?.text == "a b")
        #expect(segments.last?.text == "c")
    }

    @Test func monolithicASRSpanPreservesDiarizedSpeakers() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 10, end: 20),
            SpeakerTurn(speakerLabel: "Speaker 3", start: 20, end: 30)
        ]
        let text = (1...30).map(String.init).joined(separator: " ")
        let span = TranscribedSpan(text: text, start: 0, end: 30, confidence: nil)

        let segments = TranscriptFusion.segments(
            spans: [span],
            turns: turns,
            maxSegmentDuration: 5
        )

        #expect(segments.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 3"])
        #expect(segments.map(\.text).joined(separator: " ") == text)
        #expect(segments.map(\.startTime) == [0, 10, 20])
        #expect(segments.map(\.endTime) == [10, 20, 30])
    }

    @Test func shortSpanStillUsesMajorityOverlap() {
        let turns = [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 6),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 6, end: 10)
        ]
        let span = TranscribedSpan(
            text: "this remains a single utterance",
            start: 0,
            end: 10,
            confidence: nil
        )

        let segments = TranscriptFusion.segments(spans: [span], turns: turns)

        #expect(segments.count == 1)
        #expect(segments.first?.speakerLabel == "Speaker 1")
        #expect(segments.first?.text == span.text)
    }

    // MARK: - Confidence

    @Test func confidenceIsAveragedAcrossMergedSpans() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10)]
        let spans = [
            TranscribedSpan(text: "a", start: 0, end: 1, confidence: 0.4),
            TranscribedSpan(text: "b", start: 1, end: 2, confidence: 0.8)
        ]
        let segments = TranscriptFusion.segments(spans: spans, turns: turns)
        let confidence = segments.first?.confidence
        #expect(confidence != nil)
        #expect(abs((confidence ?? 0) - 0.6) < 0.0001)
    }

    @Test func confidenceIsNilWhenNoSpanReportsIt() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10)]
        let spans = [TranscribedSpan(text: "a", start: 0, end: 1, confidence: nil)]
        let segments = TranscriptFusion.segments(spans: spans, turns: turns)
        #expect(segments.first?.confidence == nil)
    }

    @Test func emptySpansProduceNoSegments() {
        let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 10)]
        #expect(TranscriptFusion.segments(spans: [], turns: turns).isEmpty)
    }
}

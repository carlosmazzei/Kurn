import Foundation
import Testing
@testable import KurnCore

struct TranscriptFusionBoundaryTests {
    private let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 5707.3)]

    @Test func reorderedWordsKeepTextOrderAndCoverBothIntervals() throws {
        let spans = [
            TranscribedSpan(text: "primeira", start: 301.5, end: 302, confidence: 0.4),
            TranscribedSpan(text: "segunda", start: 300.1, end: 300.4, confidence: 0.8)
        ]
        let result = TranscriptFusion.segments(spans: spans, turns: turns)
        let segment = try #require(result.first)
        #expect(result.count == 1)
        #expect(segment.text == "primeira segunda")
        #expect(segment.startTime == 300.1)
        #expect(segment.endTime == 302)
        #expect(abs((segment.confidence ?? 0) - 0.6) < 0.0001)
        #expect(TranscriptIntegrityGate.validate(segments: result, sourceDuration: 5707.3, hadTranscribedInput: true) == nil)
    }

    @Test func overlappingWordCannotShortenAnExistingSegment() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "long", start: 0, end: 10),
            TranscribedSpan(text: "overlap", start: 1, end: 2)
        ], turns: turns)
        #expect(result.count == 1)
        #expect(result.first?.endTime == 10)
        #expect(result.first?.text == "long overlap")
    }

    @Test func grossBackwardJumpStillFailsIntegrityInsteadOfBeingMergedAway() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "later", start: 100, end: 101),
            TranscribedSpan(text: "earlier", start: 0, end: 1)
        ], turns: turns)
        #expect(result.map(\.text) == ["later", "earlier"])
        #expect(TranscriptIntegrityGate.validate(segments: result, sourceDuration: 200, hadTranscribedInput: true) == .segmentsOutOfOrder)
    }

    @Test(arguments: [(-1.0, 0.5), (5.0, 2.0), (Double.nan, 2.0), (0.0, Double.infinity)])
    func invalidInputCannotBeHiddenByMerging(start: Double, end: Double) {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "before", start: 0, end: 1),
            TranscribedSpan(text: "invalid", start: start, end: end),
            TranscribedSpan(text: "after", start: 6, end: 7)
        ], turns: turns)
        #expect(result.map(\.text).joined(separator: " ") == "before invalid after")
        #expect(TranscriptIntegrityGate.validate(segments: result, sourceDuration: 5707.3, hadTranscribedInput: true) == .segmentOutOfBounds)
    }

    @Test(arguments: ["finished.", "finished!\"", "finished?”", "结束。", "结束！）", "fim…"])
    func durationSplitPrefersARecentSentenceEnd(ending: String) {
        let spans: [TranscribedSpan] = (0..<18).map { index in
            let start = Double(index) * 2
            let text = index == 11 ? ending : "word\(index)"
            return TranscribedSpan(text: text, start: start, end: start + 2, confidence: 0.7)
        }
        let result = TranscriptFusion.segments(spans: spans, turns: turns)
        #expect(result.count == 2)
        #expect(result.first?.text.hasSuffix(ending) == true)
        #expect(result.map(\.startTime) == [0, 24])
        #expect(result.map(\.endTime) == [24, 36])
        #expect(result.map(\.text).joined(separator: " ") == spans.map(\.text).joined(separator: " "))
        #expect(result.allSatisfy { abs(($0.confidence ?? 0) - 0.7) < 0.0001 })
    }

    @Test func shortSentenceDoesNotCreateAnUnnecessarilyTinyBlock() {
        let spans: [TranscribedSpan] = (0..<18).map { index in
            let start = Double(index) * 2
            let text = index == 1 ? "short." : "word\(index)"
            return TranscribedSpan(text: text, start: start, end: start + 2)
        }
        let result = TranscriptFusion.segments(spans: spans, turns: turns)
        #expect(result.map(\.endTime) == [30, 36])
        #expect(result.first?.text.contains("word14") == true)
    }

    @Test func longPauseSeparatesTheSameSpeaker() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "before", start: 0, end: 1),
            TranscribedSpan(text: "after", start: 3, end: 4)
        ], turns: turns)
        #expect(result.map(\.text) == ["before", "after"])
        #expect(result.map(\.startTime) == [0, 3])
        #expect(result.map(\.endTime) == [1, 4])
    }

    @Test func shortPauseWithinAContinuousPhraseDoesNotSplit() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "first", start: 0, end: 1),
            TranscribedSpan(text: "second", start: 1.1, end: 2)
        ], turns: turns)
        #expect(result.count == 1)
        #expect(result.first?.text == "first second")
    }

    @Test func durationSplitUsesAPhrasePauseWhenNoSentenceEndIsAvailable() {
        let spans = [
            TranscribedSpan(text: "a", start: 0, end: 8),
            TranscribedSpan(text: "b", start: 8, end: 16),
            TranscribedSpan(text: "c", start: 16.8, end: 24),
            TranscribedSpan(text: "d", start: 24, end: 29),
            TranscribedSpan(text: "e", start: 29, end: 31)
        ]
        let result = TranscriptFusion.segments(spans: spans, turns: turns)
        #expect(result.map(\.text) == ["a b", "c d e"])
        #expect(result.map(\.startTime) == [0, 16.8])
        #expect(result.map(\.endTime) == [16, 31])
    }

    @Test func speakerChangeIsNeverDelayedForPunctuation() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "unfinished", start: 0, end: 1),
            TranscribedSpan(text: "interjection", start: 1, end: 2),
            TranscribedSpan(text: "continued", start: 2, end: 3)
        ], turns: [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 1),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 1, end: 2),
            SpeakerTurn(speakerLabel: "Speaker 1", start: 2, end: 3)
        ])
        #expect(result.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(result.map(\.text) == ["unfinished", "interjection", "continued"])
    }

    @Test(arguments: [1.49, 1.5])
    func pauseThresholdIsExact(gap: Double) {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "before", start: 0, end: 1),
            TranscribedSpan(text: "after", start: 1 + gap, end: 2 + gap)
        ], turns: turns)
        #expect(result.count == (gap >= 1.5 ? 2 : 1))
    }

    @Test(arguments: [0.49, 0.5])
    func phrasePauseThresholdIsExact(gap: Double) {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "a", start: 0, end: 8),
            TranscribedSpan(text: "b", start: 8, end: 16),
            TranscribedSpan(text: "c", start: 16 + gap, end: 24),
            TranscribedSpan(text: "d", start: 24, end: 29),
            TranscribedSpan(text: "e", start: 29, end: 31)
        ], turns: turns)
        #expect(result.first?.text == (gap >= 0.5 ? "a b" : "a b c d"))
        #expect(result.map(\.text).joined(separator: " ") == "a b c d e")
    }

    @Test func sentenceBoundaryWinsOverALaterPhrasePause() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "a", start: 0, end: 8),
            TranscribedSpan(text: "b.", start: 8, end: 16),
            TranscribedSpan(text: "c", start: 16, end: 20),
            TranscribedSpan(text: "d", start: 20.7, end: 25),
            TranscribedSpan(text: "e", start: 25, end: 29),
            TranscribedSpan(text: "f", start: 29, end: 31)
        ], turns: turns)
        #expect(result.map(\.text) == ["a b.", "c d e f"])
        #expect(result.map(\.endTime) == [16, 31])
    }

    @Test func oneLongUntimedSpanIsPreservedAndDoesNotSwallowFollowingSpans() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "long utterance", start: 0, end: 70),
            TranscribedSpan(text: "next", start: 70, end: 71)
        ], turns: turns)
        #expect(result.map(\.text) == ["long utterance", "next"])
        #expect(result.map(\.startTime) == [0, 70])
        #expect(result.map(\.endTime) == [70, 71])
    }

    @Test func overflowCanFlushBothASentenceAndItsRemainingSuffix() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "a", start: 0, end: 8),
            TranscribedSpan(text: "b.", start: 8, end: 16),
            TranscribedSpan(text: "c", start: 16, end: 24),
            TranscribedSpan(text: "d", start: 24, end: 30),
            TranscribedSpan(text: "long", start: 0, end: 31)
        ], turns: turns)
        #expect(result.map(\.text) == ["a b.", "c d", "long"])
        #expect(result.map(\.startTime) == [0, 16, 0])
        #expect(result.map(\.endTime) == [16, 30, 31])
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func invalidDurationLimitFallsBackToTheDefault(limit: Double) {
        let spans = [
            TranscribedSpan(text: "a", start: 0, end: 15),
            TranscribedSpan(text: "b", start: 15, end: 30),
            TranscribedSpan(text: "c", start: 30, end: 45)
        ]
        let result = TranscriptFusion.segments(spans: spans, turns: turns, maxSegmentDuration: limit)
        #expect(result.map(\.text) == ["a b", "c"])
    }

    @Test func consecutiveInvalidSpansAtTheEdgesAreRetainedForTheGate() {
        let result = TranscriptFusion.segments(spans: [
            TranscribedSpan(text: "bad1", start: -1, end: 0),
            TranscribedSpan(text: "bad2", start: 5, end: 2),
            TranscribedSpan(text: "good", start: 6, end: 7),
            TranscribedSpan(text: "bad3", start: 10, end: 8)
        ], turns: turns)
        #expect(result.map(\.text) == ["bad1", "bad2", "good", "bad3"])
        #expect(TranscriptIntegrityGate.validate(segments: result, sourceDuration: 100, hadTranscribedInput: true) == .segmentOutOfBounds)
    }

    @Test func untimedAndEmptyResultsRemainSupported() {
        #expect(TranscriptFusion.segments(spans: [], turns: []).isEmpty)
        let result = TranscriptFusion.segments(spans: [TranscribedSpan(text: "untimed", start: 0, end: 0)], turns: [])
        #expect(result.first?.text == "untimed")
        #expect(result.first?.startTime == 0)
        #expect(result.first?.endTime == 0)
        #expect(result.first?.speakerLabel == "Speaker 1")
    }
}

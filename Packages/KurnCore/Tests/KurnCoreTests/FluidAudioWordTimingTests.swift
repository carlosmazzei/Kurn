import Foundation
import Testing
import KurnCore

struct FluidAudioWordTimingTests {
    @Test func ordinaryWordStartsUseTheNextStartAndFinalAudioBoundary() throws {
        let words = [
            FluidAudioStartTimedWord(text: " Hello,", start: 0.04),
            FluidAudioStartTimedWord(text: "world! ", start: 0.4),
            FluidAudioStartTimedWord(text: "", start: 0.8)
        ]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 1)
        #expect(result == [
            TranscribedSpan(text: " Hello,", start: 0.04, end: 0.4),
            TranscribedSpan(text: "world! ", start: 0.4, end: 0.8),
            TranscribedSpan(text: "", start: 0.8, end: 1)
        ])
    }

    @Test func duplicateStartsPreserveEveryWordIncludingZeroLengthSpans() throws {
        let words = [
            FluidAudioStartTimedWord(text: " first", start: 0.4),
            FluidAudioStartTimedWord(text: " second", start: 0.4),
            FluidAudioStartTimedWord(text: " third", start: 0.8)
        ]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 1)
        #expect(result.map(\.text) == words.map(\.text))
        #expect(result.map(\.start) == [0.4, 0.4, 0.8])
        #expect(result.map(\.end) == [0.4, 0.8, 1])
    }

    @Test func reorderingRetainsOrderAndUsesFortyMillisecondsInsteadOfAnInvertedEnd() throws {
        let words = [
            FluidAudioStartTimedWord(text: "late", start: 2),
            FluidAudioStartTimedWord(text: "early", start: 1),
            FluidAudioStartTimedWord(text: "middle", start: 1.5)
        ]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 3)
        #expect(result.map(\.text) == ["late", "early", "middle"])
        #expect(result.map(\.start) == [2, 1, 1.5])
        #expect(abs(result[0].end - 2.04) < 1e-9)
        #expect(result[1].end == 1.5)
        #expect(result[2].end == 3)
    }

    @Test func fallbackQuantumIsBoundedToTheSource() throws {
        let result = try FluidAudioWordTiming.spans(from: [
            .init(text: "tail", start: 0.99), .init(text: "earlier", start: 0.5)
        ], duration: 1)
        #expect(result.map(\.start) == [0.99, 0.5])
        #expect(result.map(\.end) == [1, 1])
    }

    @Test func finalWordDoesNotExtendAcrossTrailingSilence() throws {
        let result = try FluidAudioWordTiming.spans(from: [.init(text: "only", start: 1)], duration: 30)
        #expect(result == [TranscribedSpan(text: "only", start: 1, end: 2.5)])
        let boundary = try FluidAudioWordTiming.spans(from: [.init(text: "edge", start: 10)], duration: 10)
        #expect(boundary == [TranscribedSpan(text: "edge", start: 10, end: 10)])
    }

    @Test func longPausesDoNotBecomeEstimatedWordDurations() throws {
        #expect(FluidAudioWordTiming.maxEstimatedWordDuration == 1.5)
        let words = [
            FluidAudioStartTimedWord(text: " before ", start: 1),
            FluidAudioStartTimedWord(text: "after!", start: 21)
        ]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 50)
        #expect(result.map(\.text) == words.map(\.text))
        #expect(result.map(\.start) == [1, 21])
        #expect(result.map(\.end) == [2.5, 22.5])
    }

    @Test func wordsAtTheDurationCapAndClipBoundaryRetainTheirText() throws {
        let words = [
            FluidAudioStartTimedWord(text: "first", start: 0),
            FluidAudioStartTimedWord(text: "second", start: 1.5),
            FluidAudioStartTimedWord(text: "last", start: 3.1)
        ]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 4)
        #expect(result == [
            TranscribedSpan(text: "first", start: 0, end: 1.5),
            TranscribedSpan(text: "second", start: 1.5, end: 3),
            TranscribedSpan(text: "last", start: 3.1, end: 4)
        ])
    }

    @Test func fusionDoesNotGiveWordsToSpeakersAcrossLongPausesOrTrailingSilence() throws {
        let spans = try FluidAudioWordTiming.spans(from: [
            .init(text: "Hello", start: 0), .init(text: "Goodbye", start: 20)
        ], duration: 45)
        let turns = [
            SpeakerTurn(speakerLabel: "Host", start: 0, end: 1),
            SpeakerTurn(speakerLabel: "Guest", start: 10, end: 21),
            SpeakerTurn(speakerLabel: "Host", start: 30, end: 45)
        ]
        let segments = TranscriptFusion.segments(spans: spans, turns: turns)
        #expect(segments.map(\.text) == ["Hello", "Goodbye"])
        #expect(segments.map(\.speakerLabel) == ["Host", "Guest"])
        #expect(segments.map(\.startTime) == [0, 20])
        #expect(segments.map(\.endTime) == [1.5, 21.5])
    }

    @Test func fusionKeepsTheSameSpeakersWordsSeparatedAcrossALongPause() throws {
        let spans = try FluidAudioWordTiming.spans(from: [
            .init(text: "Before", start: 1), .init(text: "After", start: 21)
        ], duration: 25)
        let segments = TranscriptFusion.segments(spans: spans, turns: [
            SpeakerTurn(speakerLabel: "Host", start: 0, end: 25)
        ])
        #expect(segments.map(\.text) == ["Before", "After"])
        #expect(segments.map(\.speakerLabel) == ["Host", "Host"])
        #expect(segments.map(\.startTime) == [1, 21])
        #expect(segments.map(\.endTime) == [2.5, 22.5])
    }

    @Test func zeroDurationRetainsTextAtAnActualZeroBoundary() throws {
        let words = [FluidAudioStartTimedWord(text: "zero", start: 0), .init(text: " ", start: 0)]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 0)
        #expect(result.map(\.text) == ["zero", " "])
        #expect(result.map(\.start) == [0, 0])
        #expect(result.map(\.end) == [0, 0])
    }

    @Test func boundaryDriftIsNormalizedWithoutDiscardingOrTrimmingText() throws {
        let words = [
            FluidAudioStartTimedWord(text: " leading ", start: -0.08),
            FluidAudioStartTimedWord(text: "\n", start: 9.9),
            FluidAudioStartTimedWord(text: "past", start: 10.2)
        ]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 10)
        #expect(result.map(\.text) == words.map(\.text))
        #expect(result.map(\.start) == [0, 9.9, 10])
        #expect(result.map(\.end) == [1.5, 10, 10])
        #expect(result.allSatisfy { $0.confidence == nil })
    }

    @Test func emptyInputIsEmptyButStillValidatesTheDuration() throws {
        #expect(try FluidAudioWordTiming.spans(from: [], duration: 0).isEmpty)
        #expect(try FluidAudioWordTiming.spans(from: [], duration: 10).isEmpty)
        #expect(throws: ChunkTimestampNormalization.Failure.invalidDuration) {
            try FluidAudioWordTiming.spans(from: [], duration: .nan)
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -0.01])
    func invalidDurationsAreExplicitFailures(duration: TimeInterval) {
        #expect(throws: ChunkTimestampNormalization.Failure.invalidDuration) {
            try FluidAudioWordTiming.spans(from: [.init(text: "keep", start: 0)], duration: duration)
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteStartsRejectTheWholeResultRegardlessOfPosition(start: TimeInterval) {
        for index in 0..<3 {
            var words = [
                FluidAudioStartTimedWord(text: "first", start: 0),
                FluidAudioStartTimedWord(text: "second", start: 1),
                FluidAudioStartTimedWord(text: "third", start: 2)
            ]
            words[index] = .init(text: "invalid", start: start)
            #expect(throws: ChunkTimestampNormalization.Failure.nonFiniteTimestamp) {
                try FluidAudioWordTiming.spans(from: words, duration: 3)
            }
        }
    }

    @Test func grosslyInvalidStartsCannotBeHiddenByClampingOrFinalWordSynthesis() {
        let starts = [
            -ChunkTimestampNormalization.leadingBoundaryTolerance - 0.01,
            10 + ChunkTimestampNormalization.trailingBoundaryTolerance + 0.01,
            Double.greatestFiniteMagnitude
        ]
        for start in starts {
            for words in [
                [FluidAudioStartTimedWord(text: "invalid", start: start)],
                [.init(text: "invalid", start: start), .init(text: "valid", start: 1)],
                [.init(text: "valid", start: 1), .init(text: "invalid", start: start)]
            ] {
                #expect(throws: ChunkTimestampNormalization.Failure.outOfBounds) {
                    try FluidAudioWordTiming.spans(from: words, duration: 10)
                }
            }
        }
    }

    @Test func exactNormalizationTolerancesRemainAccepted() throws {
        let words = [
            FluidAudioStartTimedWord(text: "before", start: -ChunkTimestampNormalization.leadingBoundaryTolerance),
            .init(text: "after", start: 10 + ChunkTimestampNormalization.trailingBoundaryTolerance)
        ]
        let result = try FluidAudioWordTiming.spans(from: words, duration: 10)
        #expect(result == [
            TranscribedSpan(text: "before", start: 0, end: 1.5),
            TranscribedSpan(text: "after", start: 10, end: 10)
        ])
    }
}

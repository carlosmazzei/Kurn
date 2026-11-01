import Foundation
import Testing
@testable import KurnCore

struct ChunkTimestampNormalizationTests {
    private func transcript(_ start: Double, _ end: Double) -> RawTranscript {
        RawTranscript(spans: [TranscribedSpan(text: " fala ", start: start, end: end, confidence: 0.73)], language: "pt-BR")
    }

    @Test func validOverlappingAndReorderedWordsRemainUnchanged() throws {
        let spans = [
            TranscribedSpan(text: " first", start: 4, end: 5, confidence: 0.2),
            TranscribedSpan(text: " overlap", start: 4.5, end: 6, confidence: nil),
            TranscribedSpan(text: " earlier", start: 1, end: 2, confidence: 0.9),
            TranscribedSpan(text: "", start: 2, end: 2, confidence: 0)
        ]
        let turns = [SpeakerTurn(speakerLabel: "B", start: 3, end: 7), SpeakerTurn(speakerLabel: "A", start: 0, end: 4)]
        let result = try ChunkTimestampNormalization.normalize(RawTranscript(spans: spans, language: "pt-BR", speakerTurns: turns), duration: 10)
        #expect(result.spans == spans)
        #expect(result.speakerTurns == turns)
        #expect(result.language == "pt-BR")
    }

    @Test func repairsSmallBoundaryDriftWithoutLosingTextOrMetadata() throws {
        let input = RawTranscript(spans: [
            TranscribedSpan(text: " leading ", start: -0.08, end: 0.3, confidence: 0.73),
            TranscribedSpan(text: "tail!", start: 9.8, end: 10.4, confidence: nil),
            TranscribedSpan(text: "past", start: 10.2, end: 10.3, confidence: 0.1)
        ], language: "pt-BR")
        let result = try ChunkTimestampNormalization.normalize(input, duration: 10)
        #expect(result.spans.map(\.text) == input.spans.map(\.text))
        #expect(result.spans.map(\.confidence) == input.spans.map(\.confidence))
        #expect(result.spans.map(\.start) == [0, 9.8, 10])
        #expect(result.spans.map(\.end) == [0.3, 10, 10])
        #expect(result.language == input.language)
    }

    @Test func tinyInversionsCollapseWithoutDroppingTheWord() throws {
        let result = try ChunkTimestampNormalization.normalize(transcript(2.05, 2), duration: 10)
        #expect(result.spans.count == 1)
        #expect(result.spans[0].start == 2.05)
        #expect(result.spans[0].end == 2.05)
        #expect(result.spans[0].text == " fala ")
        #expect(result.spans[0].confidence == 0.73)
    }

    @Test(arguments: [(-1.01, 1.0), (9.0, 40.01), (40.01, 40.02), (5.0, 4.8), (20.0, -20.0)])
    func rejectsGrossOutliersAndInversions(bounds: (Double, Double)) {
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalize(transcript(bounds.0, bounds.1), duration: 10)
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func rejectsNonFiniteTimestamps(value: Double) {
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalize(transcript(value, 1), duration: 10)
        }
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalize(transcript(0, value), duration: nil)
        }
    }

    @Test func zeroDurationHasAnActualZeroBoundary() throws {
        let result = try ChunkTimestampNormalization.normalize(transcript(-0.1, 0.2), duration: 0)
        #expect(result.spans[0].start == 0)
        #expect(result.spans[0].end == 0)
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalize(transcript(0, 30.01), duration: 0)
        }
    }

    @Test func unknownDurationDoesNotInventAnUpperBoundary() throws {
        let input = transcript(-0.1, 100_000)
        let result = try ChunkTimestampNormalization.normalize(input, duration: nil)
        #expect(result.spans[0].start == 0)
        #expect(result.spans[0].end == 100_000)
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalize(transcript(4, 2), duration: nil)
        }
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity])
    func rejectsInvalidKnownDurations(duration: Double) {
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalize(RawTranscript(spans: [], language: ""), duration: duration)
        }
    }

    @Test func appliesTheSamePolicyToNativeTurnsAndPreservesTheirOrderAndLabels() throws {
        let input = RawTranscript(spans: [], language: "es", speakerTurns: [
            SpeakerTurn(speakerLabel: "guest", start: 9.8, end: 10.4),
            SpeakerTurn(speakerLabel: "host", start: -0.2, end: 2),
            SpeakerTurn(speakerLabel: "guest", start: 5.04, end: 5)
        ])
        let result = try ChunkTimestampNormalization.normalize(input, duration: 10)
        #expect(result.speakerTurns == [
            SpeakerTurn(speakerLabel: "guest", start: 9.8, end: 10),
            SpeakerTurn(speakerLabel: "host", start: 0, end: 2),
            SpeakerTurn(speakerLabel: "guest", start: 5.04, end: 5.04)
        ])
        #expect(result.language == "es")
    }

    @Test(arguments: [(0.0, 40.01), (40.01, 40.02), (5.0, 2.0), (Double.nan, 1.0), (0.0, Double.infinity)])
    func grosslyInvalidNativeTurnRejectsTheWholeTranscript(bounds: (Double, Double)) {
        let input = RawTranscript(spans: [TranscribedSpan(text: "keep", start: 0, end: 1)], language: "en", speakerTurns: [
            SpeakerTurn(speakerLabel: "bad", start: bounds.0, end: bounds.1)
        ])
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalize(input, duration: 10)
        }
    }

    @Test(arguments: [3.5, TranscriptIntegrityGate.boundsSlack])
    func trailingWindowPaddingClampsWordsAndNativeTurnsWithoutLosingMetadata(padding: Double) throws {
        let input = RawTranscript(spans: [
            TranscribedSpan(text: "tail", start: 9, end: 10 + padding, confidence: 0.73),
            TranscribedSpan(text: "past", start: 10 + padding, end: 10 + padding, confidence: nil)
        ], language: "pt-BR", speakerTurns: [
            SpeakerTurn(speakerLabel: "host", start: 9, end: 10 + padding),
            SpeakerTurn(speakerLabel: "guest", start: 10 + padding, end: 10 + padding)
        ])
        let result = try ChunkTimestampNormalization.normalize(input, duration: 10, offset: 600)
        #expect(result.spans == [
            TranscribedSpan(text: "tail", start: 609, end: 610, confidence: 0.73),
            TranscribedSpan(text: "past", start: 610, end: 610, confidence: nil)
        ])
        #expect(result.speakerTurns == [
            SpeakerTurn(speakerLabel: "host", start: 609, end: 610),
            SpeakerTurn(speakerLabel: "guest", start: 610, end: 610)
        ])
        #expect(result.language == input.language)
    }

    @Test func smallDriftIsNormalizedBeforeAddingTheAbsoluteOffset() throws {
        let input = RawTranscript(spans: [TranscribedSpan(text: "end", start: -0.2, end: 10.5, confidence: .nan)], language: "pt", speakerTurns: [
            SpeakerTurn(speakerLabel: "speaker", start: 9.5, end: 10.2)
        ])
        let result = try ChunkTimestampNormalization.normalize(input, duration: 10, offset: 600)
        #expect(result.spans[0].start == 600)
        #expect(result.spans[0].end == 610)
        #expect(result.spans[0].confidence?.isNaN == true)
        #expect(result.speakerTurns == [SpeakerTurn(speakerLabel: "speaker", start: 609.5, end: 610)])
    }

    @Test func acceptsExactlyTheSmallDriftLimitsAndRetainsCollapsedSpeech() throws {
        let result = try ChunkTimestampNormalization.normalize(RawTranscript(spans: [
            TranscribedSpan(text: "before", start: -1, end: -0.5),
            TranscribedSpan(text: "after", start: 10.5, end: 11),
            TranscribedSpan(text: "inverted", start: 2.1, end: 2)
        ], language: "en"), duration: 10)
        #expect(result.spans.map(\.start) == [0, 10, 2.1])
        #expect(result.spans.map(\.end) == [0, 10, 2.1])
        #expect(result.spans.map(\.text) == ["before", "after", "inverted"])
    }

    @Test(arguments: [Double.nan, Double.infinity, -1.0])
    func rejectsInvalidOffsetsBeforeOffsetting(offset: Double) {
        #expect(throws: ChunkTimestampNormalization.Failure.invalidOffset) {
            try ChunkTimestampNormalization.normalize(transcript(0, 1), duration: 10, offset: offset)
        }
    }

    @Test func rejectsOverflowInsteadOfCreatingInfinity() {
        #expect(throws: ChunkTimestampNormalization.Failure.invalidOffset) {
            try ChunkTimestampNormalization.normalize(transcript(0, 1), duration: .greatestFiniteMagnitude, offset: .greatestFiniteMagnitude)
        }
        #expect(throws: ChunkTimestampNormalization.Failure.nonFiniteTimestamp) {
            try ChunkTimestampNormalization.normalize(transcript(0, .greatestFiniteMagnitude), duration: nil, offset: .greatestFiniteMagnitude)
        }
    }

    @Test func completedSpansNormalizePerChunkWithoutSortingOrLosingMetadata() throws {
        let input = [
            TranscribedSpan(text: "tail", start: 19.8, end: 50, confidence: 0.2),
            TranscribedSpan(text: "first", start: -0.1, end: 10.4, confidence: nil),
            TranscribedSpan(text: "overlap", start: 1, end: 3, confidence: 0.9)
        ]
        let result = try ChunkTimestampNormalization.normalizeCompletedSpans(input, chunks: [
            .init(offset: 0, duration: 10), .init(offset: 10, duration: 10)
        ])
        #expect(result.map(\.text) == input.map(\.text))
        #expect(result.map(\.confidence) == input.map(\.confidence))
        #expect(result.map(\.start) == [19.8, 0, 1])
        #expect(result.map(\.end) == [20, 10, 3])
    }

    @Test func completedSpanWithSmallNegativeChunkStartCanBelongToTheNextChunk() throws {
        let result = try ChunkTimestampNormalization.normalizeCompletedSpans([
            TranscribedSpan(text: "next", start: 9.9, end: 13, confidence: 0.8)
        ], chunks: [.init(offset: 0, duration: 10), .init(offset: 10, duration: 10)])
        #expect(result == [TranscribedSpan(text: "next", start: 10, end: 13, confidence: 0.8)])
    }

    @Test(arguments: [(0.0, 40.01), (19.0, 50.01), (4.0, 2.0), (Double.nan, 3.0), (1.0, Double.infinity)])
    func corruptCompletedSpansAreNotClampedIntoThePlan(bounds: (Double, Double)) {
        #expect(throws: (any Error).self) {
            try ChunkTimestampNormalization.normalizeCompletedSpans(transcript(bounds.0, bounds.1).spans, chunks: [
                .init(offset: 0, duration: 10), .init(offset: 10, duration: 10)
            ])
        }
    }

    @Test func emptyCompletedPlanCannotOwnSpeechAndUnknownDurationsRemainSupported() throws {
        #expect(try ChunkTimestampNormalization.normalizeCompletedSpans([], chunks: []).isEmpty)
        #expect(throws: ChunkTimestampNormalization.Failure.orphanedCheckpointSpans) {
            try ChunkTimestampNormalization.normalizeCompletedSpans(transcript(0, 1).spans, chunks: [])
        }
        let spans = transcript(600, 601).spans
        #expect(try ChunkTimestampNormalization.normalizeCompletedSpans(spans, chunks: [.init(offset: 600, duration: nil)]) == spans)
    }

    @Test func invalidChunkPlansAreExplicitFailures() {
        #expect(throws: ChunkTimestampNormalization.Failure.invalidChunkPlan) {
            try ChunkTimestampNormalization.validate([.init(offset: 10, duration: 10), .init(offset: 0, duration: 10)])
        }
        #expect(throws: ChunkTimestampNormalization.Failure.invalidChunkPlan) {
            try ChunkTimestampNormalization.validate([.init(offset: 0, duration: 10), .init(offset: 0, duration: 10)])
        }
    }

    @Test func failuresRemainClosedErrorsWithoutUserFacingDescriptions() {
        let failure: any Error = ChunkTimestampNormalization.Failure.outOfBounds
        #expect(!(failure is any LocalizedError))
    }

    @Test func nilAndEmptyNativeTurnsStayDistinct() throws {
        let absent = try ChunkTimestampNormalization.normalize(RawTranscript(spans: [], language: "en"), duration: 10)
        let empty = try ChunkTimestampNormalization.normalize(RawTranscript(spans: [], language: "en", speakerTurns: []), duration: 10)
        #expect(absent.speakerTurns == nil)
        #expect(empty.speakerTurns == [])
    }
}

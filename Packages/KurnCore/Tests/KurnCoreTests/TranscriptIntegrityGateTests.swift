//
//  TranscriptIntegrityGateTests.swift
//  KurnCoreTests
//

import Foundation
import Testing
@testable import KurnCore

struct TranscriptIntegrityGateTests {

    private func segment(
        id: UUID = UUID(),
        speaker: String = "Speaker 1",
        start: TimeInterval,
        end: TimeInterval,
        text: String = "hello",
        confidence: Float? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(id: id, speakerLabel: speaker, startTime: start, endTime: end, text: text, confidence: confidence)
    }

    // MARK: - validate

    @Test func validSegmentsPassTheGate() {
        let segments = [
            segment(start: 0, end: 5),
            segment(start: 5, end: 12)
        ]
        #expect(TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true) == nil)
    }

    @Test func emptyOutputIsFineWhenTheEngineHadNoInput() {
        #expect(TranscriptIntegrityGate.validate(segments: [], sourceDuration: 20, hadTranscribedInput: false) == nil)
    }

    @Test func emptyOutputIsRejectedWhenTheEngineProducedSpans() {
        #expect(
            TranscriptIntegrityGate.validate(segments: [], sourceDuration: 20, hadTranscribedInput: true)
                == .emptyOutputFromNonEmptyInput
        )
    }

    @Test func nonFiniteSourceDurationIsRejected() {
        let segments = [segment(start: 0, end: 5)]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: .nan, hadTranscribedInput: true)
                == .sourceUnreadable
        )
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: -1, hadTranscribedInput: true)
                == .sourceUnreadable
        )
    }

    @Test func invertedSpanIsRejected() {
        let segments = [segment(start: 5, end: 2)]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true)
                == .segmentOutOfBounds
        )
    }

    @Test func negativeStartIsRejected() {
        let segments = [segment(start: -1, end: 2)]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true)
                == .segmentOutOfBounds
        )
    }

    @Test func nonFiniteSpanIsRejected() {
        let segments = [segment(start: .infinity, end: .infinity)]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true)
                == .segmentOutOfBounds
        )
    }

    @Test func spanFarBeyondSourceDurationIsRejected() {
        // 20s source, 30s slack: 60s is well outside even the generous bound.
        let segments = [segment(start: 0, end: 5), segment(start: 55, end: 60)]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true)
                == .segmentOutOfBounds
        )
    }

    @Test func spanWithinTheSlackToleranceIsAccepted() {
        // A rounding-sized overrun past the exact duration must not fail —
        // the same generosity `TranscriptionCheckpoint.isStructurallyValid` gives.
        let segments = [segment(start: 0, end: 5), segment(start: 5, end: 20.5)]
        #expect(TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true) == nil)
    }

    @Test func grosslyOutOfOrderSegmentsAreRejected() {
        let segments = [
            segment(start: 0, end: 5),
            segment(start: 100, end: 105),
            segment(start: 2, end: 8)
        ]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 200, hadTranscribedInput: true)
                == .segmentsOutOfOrder
        )
    }

    @Test func mildlyOutOfOrderSegmentsWithinSlackAreAccepted() {
        // Two segments a few seconds out of strict order (e.g. overlapping
        // speaker turns at a handover) must not trip the gross-corruption check.
        let segments = [
            segment(start: 10, end: 15),
            segment(start: 8, end: 20)
        ]
        #expect(TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 60, hadTranscribedInput: true) == nil)
    }

    @Test func blankSegmentTextIsRejected() {
        let segments = [segment(start: 0, end: 5, text: "   ")]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true)
                == .emptySegmentText
        )
    }

    @Test func blankSpeakerLabelIsRejected() {
        let segments = [segment(speaker: "  ", start: 0, end: 5)]
        #expect(
            TranscriptIntegrityGate.validate(segments: segments, sourceDuration: 20, hadTranscribedInput: true)
                == .unattributedSpeaker
        )
    }

    // MARK: - correctionPreservedIdentity

    @Test func textOnlyChangesPreserveIdentity() {
        let id = UUID()
        let original = [segment(id: id, start: 0, end: 5, text: "helo")]
        let corrected = [segment(id: id, start: 0, end: 5, text: "hello")]
        #expect(TranscriptIntegrityGate.correctionPreservedIdentity(original: original, corrected: corrected))
    }

    @Test func identicalInputPreservesIdentity() {
        let segments = [segment(start: 0, end: 5), segment(start: 5, end: 10)]
        #expect(TranscriptIntegrityGate.correctionPreservedIdentity(original: segments, corrected: segments))
    }

    @Test func mismatchedCountViolatesIdentity() {
        let original = [segment(start: 0, end: 5), segment(start: 5, end: 10)]
        let corrected = [segment(start: 0, end: 5)]
        #expect(!TranscriptIntegrityGate.correctionPreservedIdentity(original: original, corrected: corrected))
    }

    @Test func reorderedSegmentsViolateIdentity() {
        let a = segment(start: 0, end: 5)
        let b = segment(start: 5, end: 10)
        #expect(!TranscriptIntegrityGate.correctionPreservedIdentity(original: [a, b], corrected: [b, a]))
    }

    @Test func differentIdAtTheSamePositionViolatesIdentity() {
        let original = [segment(start: 0, end: 5)]
        let corrected = [segment(start: 0, end: 5)] // fresh random id
        #expect(!TranscriptIntegrityGate.correctionPreservedIdentity(original: original, corrected: corrected))
    }

    @Test func changedTimestampViolatesIdentity() {
        let id = UUID()
        let original = [segment(id: id, start: 0, end: 5)]
        let corrected = [segment(id: id, start: 1, end: 5)]
        #expect(!TranscriptIntegrityGate.correctionPreservedIdentity(original: original, corrected: corrected))
    }

    @Test func changedSpeakerLabelViolatesIdentity() {
        let id = UUID()
        let original = [segment(id: id, speaker: "Speaker 1", start: 0, end: 5)]
        let corrected = [segment(id: id, speaker: "Speaker 2", start: 0, end: 5)]
        #expect(!TranscriptIntegrityGate.correctionPreservedIdentity(original: original, corrected: corrected))
    }

    @Test func changedConfidenceViolatesIdentity() {
        let id = UUID()
        let original = [segment(id: id, start: 0, end: 5, confidence: 0.9)]
        let corrected = [segment(id: id, start: 0, end: 5, confidence: 0.1)]
        #expect(!TranscriptIntegrityGate.correctionPreservedIdentity(original: original, corrected: corrected))
    }

    @Test func emptyArraysPreserveIdentity() {
        #expect(TranscriptIntegrityGate.correctionPreservedIdentity(original: [], corrected: []))
    }
}

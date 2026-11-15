//
//  KnowledgeTranscriptRevisionTests.swift
//  KurnCoreTests
//
//  The transcript revision extraction cites: positional anchors on one
//  meeting timeline, a canonical encoding that changes with anything a
//  citation depends on and only with that, and citations checked against it.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeTranscriptRevisionTests {
    private let first = UUID()
    private let second = UUID()

    private func sources(text: String = "We will ship.", speaker: String = "Speaker 1", confidence: Float? = nil) -> [KnowledgeTranscriptSource] {
        [
            KnowledgeTranscriptSource(recordingID: first, offset: 0, segments: [
                TranscriptSegment(speakerLabel: speaker, startTime: 0, endTime: 2.5, text: text, confidence: confidence),
                TranscriptSegment(speakerLabel: "Speaker 2", startTime: 3, endTime: 4, text: "Agreed.")
            ]),
            KnowledgeTranscriptSource(recordingID: second, offset: 600, segments: [
                TranscriptSegment(speakerLabel: "Speaker 1", startTime: 1.25, endTime: 2, text: "Next part.")
            ])
        ]
    }

    @Test func anchorsAreSequentialAcrossRecordingsOnTheMeetingTimeline() throws {
        let input = sources()
        let revision = KnowledgeTranscriptRevision(sources: input)
        #expect(revision.segments.map(\.id) == ["s1", "s2", "s3"])
        #expect(revision.segments.map(\.startMs) == [0, 3_000, 601_250])
        #expect(revision.segments.map(\.endMs) == [2_500, 4_000, 602_000])
        let location = try #require(revision.location(of: "s3"))
        #expect(location.recordingID == second && location.speakerLabel == "Speaker 1")
        #expect(location.segmentID == input[1].segments[0].id)
        #expect(revision.location(of: "s4") == nil && !revision.isEmpty)
    }

    @Test func theEncodingIsDeterministicAndIgnoresSegmentIdentityAndConfidence() {
        // A re-transcription regenerates segment IDs; the same words at the
        // same times by the same speaker are the same revision.
        let one = KnowledgeTranscriptRevision(sources: sources(confidence: 0.4))
        let two = KnowledgeTranscriptRevision(sources: sources(confidence: 0.9))
        #expect(one.canonicalEncoding == two.canonicalEncoding)
    }

    @Test func theEncodingChangesWithAnythingACitationDependsOn() {
        let base = KnowledgeTranscriptRevision(sources: sources()).canonicalEncoding
        #expect(KnowledgeTranscriptRevision(sources: sources(text: "We will not ship.")).canonicalEncoding != base)
        #expect(KnowledgeTranscriptRevision(sources: sources(speaker: "Speaker 3")).canonicalEncoding != base)
        let moved = sources().map { KnowledgeTranscriptSource(recordingID: $0.recordingID, offset: $0.offset + 1, segments: $0.segments) }
        #expect(KnowledgeTranscriptRevision(sources: moved).canonicalEncoding != base)
        let reordered = Array(sources().reversed())
        #expect(KnowledgeTranscriptRevision(sources: reordered).canonicalEncoding != base)
    }

    @Test func textCannotForgeAFieldBoundary() {
        // Without length prefixes, moving a separator between fields could
        // produce the same bytes from different segments.
        let split = [KnowledgeTranscriptSource(recordingID: first, offset: 0, segments: [
            TranscriptSegment(speakerLabel: "A", startTime: 0, endTime: 1, text: "1:B")
        ])]
        let joined = [KnowledgeTranscriptSource(recordingID: first, offset: 0, segments: [
            TranscriptSegment(speakerLabel: "A1:", startTime: 0, endTime: 1, text: "B")
        ])]
        #expect(KnowledgeTranscriptRevision(sources: split).canonicalEncoding
                != KnowledgeTranscriptRevision(sources: joined).canonicalEncoding)
    }

    @Test func emptyAndNonFiniteInputsStayWellFormed() {
        let empty = KnowledgeTranscriptRevision(sources: [])
        #expect(empty.isEmpty && !empty.canonicalEncoding.isEmpty)
        let broken = KnowledgeTranscriptRevision(sources: [KnowledgeTranscriptSource(recordingID: first, offset: .nan, segments: [
            TranscriptSegment(speakerLabel: "A", startTime: 0, endTime: 1, text: "x")
        ])])
        #expect(broken.segments.first?.startMs == 0 && broken.segments.first?.endMs == 0)
    }

    @Test func citationsAreValidatedAgainstTheRevision() throws {
        let revision = KnowledgeTranscriptRevision(sources: sources())
        let accepted = try revision.validator.validate(KnowledgeEvidenceClaim(segmentIDs: ["s1", "s2"], quote: "ship. Agreed")).get()
        #expect(accepted.startMs == 0 && accepted.endMs == 4_000)
        #expect(revision.validator.validate(KnowledgeEvidenceClaim(segmentIDs: ["s1", "s3"], quote: "ship. Next")) == .failure(.segmentsNotContiguous))
        #expect(KnowledgeTranscriptRevision.anchor(at: 0) == "s1" && KnowledgeTranscriptRevision.encodingVersion == 1)
    }
}

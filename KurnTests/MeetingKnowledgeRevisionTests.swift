//
//  MeetingKnowledgeRevisionTests.swift
//  KurnTests
//
//  The meeting's transcript revision as knowledge cites it: recordings in
//  chronological order on one timeline (untranscribed ones still take their
//  time), and a SHA-256 fingerprint that a re-transcription of the same
//  words keeps and any edit changes. Synthetic content only.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingKnowledgeRevisionTests {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func meeting(in context: ModelContext) -> (Meeting, Recording, Recording) {
        let meeting = Meeting(title: "Weekly sync")
        context.insert(meeting)
        let later = Recording(meeting: meeting, fileName: "b.m4a", duration: 30, recordedAt: start.addingTimeInterval(200))
        let gap = Recording(meeting: meeting, fileName: "gap.m4a", duration: 60, recordedAt: start.addingTimeInterval(100))
        let first = Recording(meeting: meeting, fileName: "a.m4a", duration: 90, recordedAt: start)
        for recording in [later, gap, first] { context.insert(recording) }
        context.insert(Transcript(recording: first, segments: [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 4, text: "The portal ships in March."),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 5, endTime: 7, text: "Agreed.")
        ]))
        context.insert(Transcript(recording: later, segments: [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 1, endTime: 3, text: "One more thing.")
        ]))
        return (meeting, first, later)
    }

    @Test func recordingsAreAnchoredInOrderAndTheGapStillTakesItsTime() throws {
        let context = ModelContext(TestModelContainer.make())
        let (meeting, first, later) = meeting(in: context)
        let revision = meeting.knowledgeTranscriptRevision()
        #expect(revision.segments.map(\.id) == ["s1", "s2", "s3"])
        // `later` starts after `first` (90 s) and the untranscribed `gap` (60 s).
        #expect(revision.segments.map(\.startMs) == [0, 5_000, 151_000])
        #expect(revision.location(of: "s1")?.recordingID == first.id)
        #expect(revision.location(of: "s3")?.recordingID == later.id)
        _ = try revision.validator.validate(KnowledgeEvidenceClaim(segmentIDs: ["s1"], quote: "ships in March")).get()
    }

    @Test func theFingerprintIsSHA256HexAndFollowsTheWordsNotTheSegmentIDs() throws {
        let context = ModelContext(TestModelContainer.make())
        let (meeting, first, _) = meeting(in: context)
        let original = meeting.knowledgeTranscriptRevision().fingerprint
        #expect(original.count == 64 && original.allSatisfy { "0123456789abcdef".contains($0) })

        let transcript = try #require(first.transcript)
        // A re-transcription with the same words: new segment IDs, same revision.
        transcript.segments = transcript.segments.map {
            TranscriptSegment(speakerLabel: $0.speakerLabel, startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
        }
        #expect(meeting.knowledgeTranscriptRevision().fingerprint == original)

        // An edit is a new revision.
        var edited = transcript.segments
        edited[0].text = "The portal ships in April."
        transcript.segments = edited
        #expect(meeting.knowledgeTranscriptRevision().fingerprint != original)
    }

    @Test func aMeetingWithNothingTranscribedHasAnEmptyRevision() {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Meeting(title: "Not yet")
        context.insert(meeting)
        context.insert(Recording(meeting: meeting, fileName: "x.m4a", duration: 10))
        let revision = meeting.knowledgeTranscriptRevision()
        #expect(revision.isEmpty && revision.fingerprint.count == 64)
    }
}

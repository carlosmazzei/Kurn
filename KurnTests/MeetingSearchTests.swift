//
//  MeetingSearchTests.swift
//  KurnTests
//
//  Verifies `Meeting.matches(search:)` looks beyond the title into notes and
//  the transcript plain text — the behavior the meetings list relies on for
//  full-text search across recordings.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingSearchTests {

    private func makeMeeting(
        title: String = "Standup",
        notes: String = "",
        transcriptSegments: [TranscriptSegment] = []
    ) -> Meeting {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Meeting(title: title, notes: notes)
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "r.m4a", duration: 30)
        context.insert(recording)
        if !transcriptSegments.isEmpty {
            let transcript = Transcript(recording: recording, segments: transcriptSegments)
            context.insert(transcript)
        }
        return meeting
    }

    @Test func emptyNeedleAlwaysMatches() {
        let meeting = makeMeeting()
        #expect(meeting.matches(search: "") == true)
    }

    @Test func matchesTitleCaseInsensitive() {
        let meeting = makeMeeting(title: "Quarterly Planning")
        #expect(meeting.matches(search: "PLANNING") == true)
        #expect(meeting.matches(search: "absent") == false)
    }

    @Test func matchesNotesContent() {
        let meeting = makeMeeting(title: "Standup", notes: "Discuss the iceberg risk")
        #expect(meeting.matches(search: "iceberg") == true)
    }

    @Test func matchesWordInsideTranscriptSegment() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "Hello team"),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 5, endTime: 10, text: "Let us discuss the roadmap")
        ]
        let meeting = makeMeeting(title: "Standup", transcriptSegments: segments)
        // "roadmap" only appears inside the transcript — neither title nor notes.
        #expect(meeting.matches(search: "roadmap") == true)
    }

    @Test func failsWhenNeedleAppearsNowhere() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "Hello team")
        ]
        let meeting = makeMeeting(title: "Standup", notes: "Weekly sync", transcriptSegments: segments)
        #expect(meeting.matches(search: "deadline") == false)
    }
}

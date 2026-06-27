//
//  MeetingExportTests.swift
//  KurnTests
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingExportTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func markdownIncludesTitleAndNotes() {
        let meeting = Meeting(title: "Sprint Planning", notes: "Bring laptops")
        let markdown = MeetingExport.markdown(for: meeting)
        #expect(markdown.contains("# Sprint Planning"))
        #expect(markdown.contains("## Notes"))
        #expect(markdown.contains("Bring laptops"))
    }

    @Test func markdownOmitsNotesSectionWhenEmpty() {
        let meeting = Meeting(title: "Sprint Planning")
        let markdown = MeetingExport.markdown(for: meeting)
        #expect(!markdown.contains("## Notes"))
    }

    @Test func markdownRendersTemplateSections() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)
        let summary = Summary(
            meeting: meeting,
            sections: [
                SummarySection(title: "Recap", body: "We aligned on scope."),
                SummarySection(title: "Decisions", items: ["Ship next week"]),
                SummarySection(title: "Actions", items: ["Write tests"])
            ],
            provider: .openAI
        )
        context.insert(summary)
        meeting.summary = summary

        let markdown = MeetingExport.markdown(for: meeting)
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("### Recap"))
        #expect(markdown.contains("We aligned on scope."))
        #expect(markdown.contains("### Decisions"))
        #expect(markdown.contains("- Ship next week"))
        #expect(markdown.contains("### Actions"))
        #expect(markdown.contains("- Write tests"))
    }

    @Test func markdownUsesSpeakerDisplayNameInTranscript() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)

        let speaker = Speaker(meeting: meeting, label: "Speaker 1", name: "Carlos", color: "#FFFFFF")
        context.insert(speaker)

        let recording = Recording(meeting: meeting, fileName: "a.m4a", duration: 10)
        context.insert(recording)

        let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "Let's begin")
        let transcript = Transcript(recording: recording, segments: [segment])
        context.insert(transcript)
        recording.transcript = transcript

        let markdown = MeetingExport.markdown(for: meeting)
        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("Carlos:"))
        #expect(markdown.contains("Let's begin"))
    }

    @Test func markdownNumbersMultipleTranscribedSegmentsAsSegments() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)

        let baseDate = Date()
        for index in 0..<2 {
            let recording = Recording(
                meeting: meeting, fileName: "r\(index).m4a", duration: 10,
                recordedAt: baseDate.addingTimeInterval(TimeInterval(index * 60))
            )
            context.insert(recording)
            let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "part \(index)")
            let transcript = Transcript(recording: recording, segments: [segment])
            context.insert(transcript)
            recording.transcript = transcript
        }

        let markdown = MeetingExport.markdown(for: meeting)
        #expect(markdown.contains("### Segment 1"))
        #expect(markdown.contains("### Segment 2"))
    }

    @Test func markdownUsesAbsoluteTimestampsAcrossSegments() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)

        let baseDate = Date()
        // Two 30s recordings; each has a segment at its own 0:00. The second
        // recording starts 30s into the meeting, so its segment must read 0:30.
        for index in 0..<2 {
            let recording = Recording(
                meeting: meeting, fileName: "r\(index).m4a", duration: 30,
                recordedAt: baseDate.addingTimeInterval(TimeInterval(index * 60))
            )
            context.insert(recording)
            let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "part \(index)")
            let transcript = Transcript(recording: recording, segments: [segment])
            context.insert(transcript)
            recording.transcript = transcript
        }

        let markdown = MeetingExport.markdown(for: meeting)
        #expect(markdown.contains("[0:00] Speaker 1:** part 0"))
        #expect(markdown.contains("[0:30] Speaker 1:** part 1"))
    }

    @Test func temporaryFileSanitizesTitleForFileName() throws {
        let meeting = Meeting(title: "Q&A: Sprint / Review?")
        let url = try MeetingExport.temporaryFile(for: meeting)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "md")
        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.lastPathComponent.contains("?"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func temporaryFileFallsBackToDefaultNameWhenTitleHasNoAlphanumerics() throws {
        let meeting = Meeting(title: "###")
        let url = try MeetingExport.temporaryFile(for: meeting)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.lastPathComponent == "meeting.md")
    }
}

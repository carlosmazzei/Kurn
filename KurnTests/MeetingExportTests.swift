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
        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
        #expect(markdown.contains("# Sprint Planning"))
        #expect(markdown.contains("## Notes"))
        #expect(markdown.contains("Bring laptops"))
    }

    @Test func markdownOmitsNotesSectionWhenEmpty() {
        let meeting = Meeting(title: "Sprint Planning")
        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
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

        let markdown = MeetingExport.markdown(for: meeting, summary: summary)
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("### Recap"))
        #expect(markdown.contains("We aligned on scope."))
        #expect(markdown.contains("### Decisions"))
        #expect(markdown.contains("- Ship next week"))
        #expect(markdown.contains("### Actions"))
        #expect(markdown.contains("- Write tests"))
    }

    @Test func markdownRendersOnlyTheSelectedSummaryWhenMultipleExist() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)
        let general = Summary(
            meeting: meeting,
            sections: [SummarySection(title: "General", body: "General recap")],
            templateName: "General",
            provider: .openAI
        )
        let standup = Summary(
            meeting: meeting,
            sections: [SummarySection(title: "Standup", body: "Standup recap")],
            templateName: "Standup",
            provider: .openAI
        )
        context.insert(general)
        context.insert(standup)

        let markdown = MeetingExport.markdown(for: meeting, summary: standup)
        #expect(markdown.contains("Standup recap"))
        #expect(!markdown.contains("General recap"))
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

        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
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

        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
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

        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
        #expect(markdown.contains("[0:00] Speaker 1:** part 0"))
        #expect(markdown.contains("[0:30] Speaker 1:** part 1"))
    }

    @Test func temporaryFileSanitizesTitleForFileName() throws {
        let meeting = Meeting(title: "Q&A: Sprint / Review?")
        let url = try MeetingExport.temporaryFile(for: meeting, summary: nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(url.pathExtension == "md")
        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.lastPathComponent.contains("?"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func temporaryFileFallsBackToDefaultNameWhenTitleHasNoAlphanumerics() throws {
        let meeting = Meeting(title: "###")
        let url = try MeetingExport.temporaryFile(for: meeting, summary: nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "meeting.md")
    }

    @Test func temporaryFileIsUniquePerCallEvenForIdenticalTitles() throws {
        let first = Meeting(title: "Standup")
        let second = Meeting(title: "Standup")
        let firstURL = try MeetingExport.temporaryFile(for: first, summary: nil)
        let secondURL = try MeetingExport.temporaryFile(for: second, summary: nil)
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        #expect(firstURL != secondURL)
        #expect(firstURL.deletingLastPathComponent() != secondURL.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test func transcriptMarkdownIncludesOnlyThatRecordingsSegments() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)

        let baseDate = Date()
        var recordings: [Recording] = []
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
            recordings.append(recording)
        }

        let markdown = MeetingExport.transcriptMarkdown(for: meeting, recording: recordings[0])
        #expect(markdown.contains("# Sprint Planning"))
        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("part 0"))
        #expect(!markdown.contains("part 1"))
        #expect(!markdown.contains("### Segment"))
    }

    @Test func summaryMarkdownIncludesOnlyThatSummarysSections() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)
        let general = Summary(
            meeting: meeting,
            sections: [SummarySection(title: "General", body: "General recap")],
            templateName: "General",
            provider: .openAI
        )
        let standup = Summary(
            meeting: meeting,
            sections: [SummarySection(title: "Standup", body: "Standup recap")],
            templateName: "Standup",
            provider: .openAI
        )
        context.insert(general)
        context.insert(standup)

        let markdown = MeetingExport.summaryMarkdown(for: meeting, summary: standup)
        #expect(markdown.contains("# Sprint Planning"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("Standup recap"))
        #expect(!markdown.contains("General recap"))
    }

    @Test func temporaryFileWithSuggestedNameSanitizesAndWritesText() throws {
        let url = try MeetingExport.temporaryFile(markdown: "hello world", suggestedName: "Q&A: Sprint / Review?")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(url.pathExtension == "md")
        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.lastPathComponent.contains("?"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello world")
    }
}

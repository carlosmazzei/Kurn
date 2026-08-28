//
//  MeetingExportTests.swift
//  KurnTests
//

import Foundation
import KurnCore
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

    @Test func markdownPrefixesHighlightedTranscriptLines() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)

        let recording = Recording(
            meeting: meeting, fileName: "a.m4a", duration: 10,
            highlights: [Highlight(timestamp: 6)]
        )
        context.insert(recording)

        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "not highlighted"),
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 5, endTime: 10, text: "highlighted")
        ]
        let transcript = Transcript(recording: recording, segments: segments)
        context.insert(transcript)
        recording.transcript = transcript

        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
        #expect(markdown.contains("**[0:00] Speaker 1:** not highlighted"))
        #expect(markdown.contains("⭐ **[0:05] Speaker 1:** highlighted"))
    }

    @Test func markdownIncludesHighlightsSectionWhenPresent() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)

        let recording = Recording(
            meeting: meeting, fileName: "a.m4a", duration: 10,
            highlights: [Highlight(timestamp: 12), Highlight(timestamp: 3)]
        )
        context.insert(recording)

        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
        #expect(markdown.contains("## Highlights"))
        // Chronological, not insertion order.
        let highlightsRange = markdown.range(of: "## Highlights")!
        let afterHighlights = markdown[highlightsRange.upperBound...]
        let threeIndex = afterHighlights.range(of: "- 0:03")!.lowerBound
        let twelveIndex = afterHighlights.range(of: "- 0:12")!.lowerBound
        #expect(threeIndex < twelveIndex)
    }

    @Test func markdownOmitsHighlightsSectionWhenNoneMarked() {
        let meeting = Meeting(title: "Sprint Planning")
        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
        #expect(!markdown.contains("## Highlights"))
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

    // MARK: - Obsidian-style export

    @Test func markdownOmitsFrontmatterByDefault() {
        let meeting = Meeting(title: "Sprint Planning")
        let markdown = MeetingExport.markdown(for: meeting, summary: nil)
        #expect(!markdown.hasPrefix("---"))
    }

    @Test func obsidianStyleMarkdownIncludesFrontmatterWithTitleAndDate() {
        let meeting = Meeting(title: "Sprint Planning")
        let markdown = MeetingExport.markdown(for: meeting, summary: nil, obsidianStyle: true)
        #expect(markdown.hasPrefix("---\n"))
        #expect(markdown.contains("title: \"Sprint Planning\""))
        #expect(markdown.contains("date: "))
        // Frontmatter closes before the title heading.
        let frontmatterEnd = markdown.range(of: "\n---\n")!
        let titleRange = markdown.range(of: "# Sprint Planning")!
        #expect(frontmatterEnd.upperBound < titleRange.lowerBound)
    }

    @Test func obsidianStyleMarkdownOmitsTagsFolderAndFavoriteWhenAbsent() {
        let meeting = Meeting(title: "Sprint Planning")
        let markdown = MeetingExport.markdown(for: meeting, summary: nil, obsidianStyle: true)
        #expect(!markdown.contains("tags:"))
        #expect(!markdown.contains("folder:"))
        #expect(!markdown.contains("favorite:"))
    }

    @Test func obsidianStyleMarkdownIncludesTagsFolderAndFavoriteWhenPresent() {
        let context = makeContext()
        let folder = Folder(name: "Product")
        context.insert(folder)
        let meeting = Meeting(title: "Sprint Planning", isFavorite: true, folder: folder)
        context.insert(meeting)
        let tag = Tag(name: "weekly")
        context.insert(tag)
        meeting.tags = [tag]

        let markdown = MeetingExport.markdown(for: meeting, summary: nil, obsidianStyle: true)
        #expect(markdown.contains("tags: [\"weekly\"]"))
        #expect(markdown.contains("folder: \"Product\""))
        #expect(markdown.contains("favorite: true"))
    }

    @Test func obsidianStyleMarkdownJoinsNestedFolderNamesWithSlash() {
        let context = makeContext()
        let parent = Folder(name: "Product")
        context.insert(parent)
        let child = Folder(name: "Roadmap", parent: parent)
        context.insert(child)
        let meeting = Meeting(title: "Sprint Planning", folder: child)
        context.insert(meeting)

        let markdown = MeetingExport.markdown(for: meeting, summary: nil, obsidianStyle: true)
        #expect(markdown.contains("folder: \"Product/Roadmap\""))
    }

    @Test func obsidianStyleMarkdownEscapesQuotesInTitle() {
        let meeting = Meeting(title: "Say \"hi\" to Q3")
        let markdown = MeetingExport.markdown(for: meeting, summary: nil, obsidianStyle: true)
        #expect(markdown.contains("title: \"Say \\\"hi\\\" to Q3\""))
    }

    @Test func obsidianStyleMarkdownWrapsSpeakerNamesAsWikilinks() {
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

        let markdown = MeetingExport.markdown(for: meeting, summary: nil, obsidianStyle: true)
        #expect(markdown.contains("[[Carlos]]:"))

        let plainMarkdown = MeetingExport.markdown(for: meeting, summary: nil, obsidianStyle: false)
        #expect(!plainMarkdown.contains("[[Carlos]]"))
        #expect(plainMarkdown.contains("Carlos:"))
    }

    @Test func transcriptAndSummaryMarkdownSupportObsidianStyleToo() {
        let context = makeContext()
        let meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)
        let summary = Summary(
            meeting: meeting,
            sections: [SummarySection(title: "Recap", body: "We aligned on scope.")],
            provider: .openAI
        )
        context.insert(summary)
        let recording = Recording(meeting: meeting, fileName: "a.m4a", duration: 10)
        context.insert(recording)
        let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "Let's begin")
        let transcript = Transcript(recording: recording, segments: [segment])
        context.insert(transcript)
        recording.transcript = transcript

        let transcriptMarkdown = MeetingExport.transcriptMarkdown(for: meeting, recording: recording, obsidianStyle: true)
        #expect(transcriptMarkdown.hasPrefix("---\n"))
        #expect(transcriptMarkdown.contains("[[Speaker 1]]:"))

        let summaryMarkdown = MeetingExport.summaryMarkdown(for: meeting, summary: summary, obsidianStyle: true)
        #expect(summaryMarkdown.hasPrefix("---\n"))
    }
}

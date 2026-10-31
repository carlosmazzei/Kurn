//
//  MeetingBulkExportTests.swift
//  KurnTests
//
//  Export planning for several meetings at once: which meetings have
//  something to export, one file per meeting versus one combined file, and
//  what each document carries.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingBulkExportTests {

    private let container: ModelContainer
    private let context: ModelContext

    init() {
        container = TestModelContainer.make()
        context = container.mainContext
        context.autosaveEnabled = false
    }

    private func makeMeeting(
        _ title: String,
        day: Int,
        summary: String? = nil,
        transcript: String? = nil
    ) -> Meeting {
        let meeting = Meeting(title: title, createdAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400 + 43_200))
        context.insert(meeting)
        if let summary {
            context.insert(Summary(
                meeting: meeting,
                sections: [SummarySection(title: "Recap", body: summary)],
                templateName: "General",
                provider: .openAI
            ))
        }
        if let transcript {
            let recording = Recording(meeting: meeting, fileName: "\(UUID().uuidString).m4a", duration: 10)
            context.insert(recording)
            let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: transcript)
            let row = Transcript(recording: recording, segments: [segment])
            context.insert(row)
            recording.transcript = row
        }
        return meeting
    }

    @Test func meetingsAreOrderedOldestFirst() {
        let newer = makeMeeting("Newer", day: 2, summary: "n")
        let older = makeMeeting("Older", day: 1, summary: "o")
        let export = MeetingBulkExport(meetings: [newer, older])
        #expect(export.meetings.map(\.id) == [older.id, newer.id])
    }

    @Test func onlyMeetingsWithIncludedContentAreExportable() {
        let summarized = makeMeeting("Summarized", day: 1, summary: "decided X")
        let transcribed = makeMeeting("Transcribed", day: 2, transcript: "hello")
        let empty = makeMeeting("Empty", day: 3)
        var export = MeetingBulkExport(meetings: [summarized, transcribed, empty])
        #expect(export.exportableMeetings.map(\.id) == [summarized.id, transcribed.id])
        #expect(export.availabilityText == String(
            format: NSLocalizedString("bulk_export.availability", comment: ""), 2, 3
        ))

        export.includesTranscripts = false
        #expect(export.exportableMeetings.map(\.id) == [summarized.id])

        export.includesSummaries = false
        #expect(!export.canExport)
        #expect(export.exportItems().isEmpty)
        #expect(export.clipboardText().isEmpty)
        #expect(export.fileCount == 0)
        #expect(export.shareButtonTitle == NSLocalizedString("share.share_action", comment: ""))
    }

    @Test func filePerMeetingNamesEachFileByDateAndTitle() {
        let first = makeMeeting("Kickoff", day: 1, summary: "Kickoff recap", transcript: "kickoff words")
        let second = makeMeeting("Retro", day: 2, transcript: "retro words")
        var export = MeetingBulkExport(meetings: [second, first])
        export.format = .obsidian

        let items = export.exportItems()
        #expect(items.map(\.suggestedName) == [
            "\(MeetingBulkExport.fileDate(first.createdAt)) Kickoff",
            "\(MeetingBulkExport.fileDate(second.createdAt)) Retro"
        ])
        #expect(items.allSatisfy { $0.format == .obsidian })
        #expect(items[0].markdown.hasPrefix("---\n"))
        #expect(items[0].markdown.contains("Kickoff recap"))
        #expect(items[0].markdown.contains("kickoff words"))
        #expect(items[1].markdown.contains("retro words"))
        #expect(export.fileCount == 2)
        #expect(export.shareButtonTitle == "\(NSLocalizedString("share.share_action", comment: "")) (2)")
    }

    @Test func excludedPartsAreLeftOutOfEachDocument() {
        let meeting = makeMeeting("Kickoff", day: 1, summary: "Kickoff recap", transcript: "kickoff words")
        var export = MeetingBulkExport(meetings: [meeting])

        export.includesTranscripts = false
        let summaryOnly = MarkdownExportRenderer.render(export.document(for: meeting))
        #expect(summaryOnly.contains("Kickoff recap"))
        #expect(!summaryOnly.contains("kickoff words"))

        export.includesTranscripts = true
        export.includesSummaries = false
        let transcriptOnly = MarkdownExportRenderer.render(export.document(for: meeting))
        #expect(!transcriptOnly.contains("Kickoff recap"))
        #expect(transcriptOnly.contains("kickoff words"))
    }

    @Test func singleFileGroupsEveryMeetingUnderItsTitle() {
        let first = makeMeeting("Kickoff", day: 1, summary: "Kickoff recap")
        let second = makeMeeting("Retro", day: 2, transcript: "retro words")
        let skipped = makeMeeting("Empty", day: 3)
        var export = MeetingBulkExport(meetings: [first, second, skipped])
        export.grouping = .singleFile
        export.format = .pdf

        let items = export.exportItems()
        #expect(items.count == 1)
        #expect(export.fileCount == 1)
        #expect(items[0].format == .pdf)
        #expect(items[0].suggestedName == "Kurn meetings \(MeetingBulkExport.fileDate(second.createdAt))")

        let document = items[0].document
        #expect(document.title == String(
            format: NSLocalizedString("bulk_export.combined_title", comment: ""), 2
        ))
        #expect(document.dateLine.contains(" – "))
        let markdown = items[0].markdown
        let kickoff = markdown.range(of: "# Kickoff\n")?.lowerBound
        let retro = markdown.range(of: "# Retro\n")?.lowerBound
        #expect(kickoff != nil && retro != nil)
        if let kickoff, let retro { #expect(kickoff < retro) }
        #expect(markdown.contains("Kickoff recap"))
        #expect(markdown.contains("retro words"))
        #expect(!markdown.contains("# Empty\n"))
    }

    @Test func singleMeetingCombinedDateLineHasNoRange() {
        let meeting = makeMeeting("Kickoff", day: 1, summary: "Kickoff recap")
        let document = MeetingBulkExport(meetings: [meeting]).combinedDocument()
        #expect(!document.dateLine.contains(" – "))
        #expect(!document.dateLine.isEmpty)
    }

    @Test func clipboardTextHoldsEveryMeetingWhateverTheGrouping() {
        let first = makeMeeting("Kickoff", day: 1, summary: "Kickoff recap")
        let second = makeMeeting("Retro", day: 2, transcript: "retro words")
        var export = MeetingBulkExport(meetings: [first, second])
        export.format = .plainText
        let text = export.clipboardText()
        #expect(text.contains("Kickoff recap"))
        #expect(text.contains("retro words"))
    }

    @Test func groupingTitlesAreLocalized() {
        for grouping in MeetingBulkExport.Grouping.allCases {
            #expect(!grouping.title.isEmpty)
            #expect(!grouping.detail.isEmpty)
            #expect(grouping.id == grouping.rawValue)
        }
    }
}

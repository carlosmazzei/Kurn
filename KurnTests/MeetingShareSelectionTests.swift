//
//  MeetingShareSelectionTests.swift
//  KurnTests
//
//  Selection defaults, toggling, button title and export planning behind the
//  share sheet — everything the view does apart from writing files and the
//  pasteboard.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingShareSelectionTests {

    private let container: ModelContainer
    private let context: ModelContext
    private let meeting: Meeting

    init() {
        container = TestModelContainer.make()
        context = container.mainContext
        // Every test leaves unsaved inserts behind; the main context's
        // run-loop autosave must not fire against a container this
        // instance has already released.
        context.autosaveEnabled = false
        meeting = Meeting(title: "Sprint Planning")
        context.insert(meeting)
    }

    @discardableResult
    private func addRecording(
        at offset: TimeInterval,
        transcribed: Bool = true,
        captureState: RecordingCaptureState = .ready
    ) -> Recording {
        let recording = Recording(
            meeting: meeting,
            fileName: "r\(Int(offset)).m4a",
            duration: 10,
            recordedAt: Date(timeIntervalSince1970: 1_000 + offset),
            captureState: captureState
        )
        context.insert(recording)
        if transcribed {
            let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "part \(Int(offset))")
            let transcript = Transcript(recording: recording, segments: [segment])
            context.insert(transcript)
            recording.transcript = transcript
        }
        return recording
    }

    @discardableResult
    private func addSummary(template: String?, at offset: TimeInterval) -> Summary {
        let summary = Summary(
            meeting: meeting,
            sections: [SummarySection(title: "Recap", body: "Recap \(template ?? "untitled")")],
            templateName: template,
            provider: .openAI,
            createdAt: Date(timeIntervalSince1970: 2_000 + offset)
        )
        context.insert(summary)
        return summary
    }

    // MARK: - Defaults

    @Test func defaultsToTranscribedReadyRecordingsAndThePreselectedSummary() {
        let transcribed = addRecording(at: 0)
        addRecording(at: 60, transcribed: false)
        addRecording(at: 120, captureState: .recoveryNeeded)
        let shown = addSummary(template: "General", at: 0)
        addSummary(template: "Standup", at: 10)

        let selection = MeetingShareSelection(meeting: meeting, preselectedSummary: shown)
        #expect(selection.selectedRecordingIDs == [transcribed.id])
        #expect(selection.selectedSummaryIDs == [shown.id])
        #expect(selection.format == .standard)
        #expect(selection.selectionCount == 2)
    }

    @Test func noPreselectedSummaryAndNoTranscriptsMeansNothingSelected() {
        addRecording(at: 0, transcribed: false)
        let selection = MeetingShareSelection(meeting: meeting, preselectedSummary: nil)
        #expect(!selection.hasSelection)
        #expect(selection.shareButtonTitle == NSLocalizedString("share.share_action", comment: ""))
        #expect(selection.combinedMarkdown().isEmpty)
        #expect(selection.exportItems().isEmpty)
    }

    // MARK: - Ordering

    @Test func summariesAreNewestFirstAndTranscriptsKeepMeetingNumbering() {
        addRecording(at: 0, transcribed: false)
        let second = addRecording(at: 60)
        let third = addRecording(at: 120)
        let older = addSummary(template: "Older", at: 0)
        let newer = addSummary(template: "Newer", at: 10)

        let selection = MeetingShareSelection(meeting: meeting, preselectedSummary: nil)
        #expect(selection.sortedSummaries.map(\.id) == [newer.id, older.id])
        #expect(selection.transcribedRecordings.map(\.index) == [1, 2])
        #expect(selection.transcribedRecordings.map(\.recording.id) == [second.id, third.id])
    }

    // MARK: - Toggling

    @Test func togglingFlipsMembershipAndUpdatesTheButtonTitle() {
        let recording = addRecording(at: 0)
        let summary = addSummary(template: "General", at: 0)
        var selection = MeetingShareSelection(meeting: meeting, preselectedSummary: summary)
        let share = NSLocalizedString("share.share_action", comment: "")
        #expect(selection.shareButtonTitle == "\(share) (2)")

        selection.toggle(recording)
        #expect(!selection.isSelected(recording))
        #expect(selection.shareButtonTitle == "\(share) (1)")

        selection.toggle(summary)
        #expect(!selection.isSelected(summary))
        #expect(!selection.hasSelection)
        #expect(selection.shareButtonTitle == share)

        selection.toggle(recording)
        #expect(selection.isSelected(recording))
    }

    // MARK: - Titles

    @Test func summaryTitleUsesTemplateNameOrFallsBack() {
        let named = addSummary(template: "Standup", at: 0)
        let blank = addSummary(template: "", at: 1)
        let missing = addSummary(template: nil, at: 2)
        let fallback = NSLocalizedString("detail.summary.untitled", comment: "")

        #expect(MeetingShareSelection.summaryTitle(for: named) == "Standup · \(named.createdAt.shortTime)")
        #expect(MeetingShareSelection.summaryTitle(for: blank) == "\(fallback) · \(blank.createdAt.shortTime)")
        #expect(MeetingShareSelection.summaryTitle(for: missing) == "\(fallback) · \(missing.createdAt.shortTime)")
    }

    @Test func transcriptTitleIsOneBased() {
        let expected = String(format: NSLocalizedString("detail.recording_n", comment: ""), 3)
        #expect(MeetingShareSelection.transcriptTitle(index: 2) == expected)
    }

    // MARK: - Export planning

    @Test func exportItemsListSummariesThenTranscriptsWithSuggestedNames() {
        addRecording(at: 0, transcribed: false)
        addRecording(at: 60)
        let older = addSummary(template: "General", at: 0)
        let unnamed = addSummary(template: nil, at: 10)
        var selection = MeetingShareSelection(meeting: meeting, preselectedSummary: older)
        selection.toggle(unnamed)

        let items = selection.exportItems()
        #expect(items.map(\.suggestedName) == [
            "Sprint Planning-summary-1",
            "Sprint Planning-summary-General",
            "Sprint Planning-transcript-2"
        ])
        #expect(items[0].markdown.contains("Recap untitled"))
        #expect(items[1].markdown.contains("Recap General"))
        #expect(items[2].markdown.contains("part 60"))
    }

    @Test func exportItemsOnlyIncludeSelectedEntries() {
        addRecording(at: 0)
        let second = addRecording(at: 60)
        let summary = addSummary(template: "General", at: 0)
        var selection = MeetingShareSelection(meeting: meeting, preselectedSummary: nil)
        selection.toggle(second)

        let items = selection.exportItems()
        #expect(items.map(\.suggestedName) == ["Sprint Planning-transcript-1"])
        #expect(!items[0].markdown.contains("Recap General"))
        _ = summary
    }

    @Test func combinedMarkdownJoinsExportsWithTheSeparator() {
        addRecording(at: 0)
        let summary = addSummary(template: "General", at: 0)
        let selection = MeetingShareSelection(meeting: meeting, preselectedSummary: summary)

        let combined = selection.combinedMarkdown()
        let parts = combined.components(separatedBy: MeetingShareSelection.combinedSeparator)
        #expect(parts.count == 2)
        #expect(parts[0].contains("Recap General"))
        #expect(parts[1].contains("part 0"))
    }

    @Test func obsidianFormatSwitchesEveryExportToFrontmatterStyle() {
        addRecording(at: 0)
        let summary = addSummary(template: "General", at: 0)
        var selection = MeetingShareSelection(meeting: meeting, preselectedSummary: summary)

        #expect(selection.exportItems().allSatisfy { !$0.markdown.hasPrefix("---") })
        selection.format = .obsidian
        #expect(selection.format.isObsidianStyle)
        #expect(selection.exportItems().allSatisfy { $0.markdown.hasPrefix("---") })
    }

    @Test func formatMetadataIsLocalizedPerCase() {
        #expect(MeetingShareFormat.allCases == [.standard, .obsidian])
        #expect(MeetingShareFormat.standard.title == NSLocalizedString("share.format.standard", comment: ""))
        #expect(MeetingShareFormat.obsidian.explanation == NSLocalizedString("share.format.obsidian.detail", comment: ""))
        #expect(!MeetingShareFormat.standard.isObsidianStyle)
    }
}

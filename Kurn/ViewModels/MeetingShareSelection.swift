//
//  MeetingShareSelection.swift
//  Kurn
//
//  Selection state and export planning behind `MeetingShareSelectionView`:
//  which summaries/transcripts are picked, in which format, and what Markdown
//  (and file names) that selection turns into. The view owns only the
//  side effects — pasteboard, temporary files, dismissal.
//

import Foundation
import KurnCore

/// Output format for every export in the share sheet: standard plain
/// Markdown, or "Obsidian" (YAML frontmatter + `[[wikilinks]]` for speakers)
/// — see `MeetingExport.markdown(for:summary:obsidianStyle:)`.
enum MeetingShareFormat: String, CaseIterable {
    case standard, obsidian

    var title: String {
        switch self {
        case .standard: NSLocalizedString("share.format.standard", comment: "Standard")
        case .obsidian: NSLocalizedString("share.format.obsidian", comment: "Obsidian")
        }
    }

    /// What the choice actually changes in the exported file. Without it
    /// "Obsidian" is just a word next to "Standard" — nothing else on the
    /// screen reacts to the picker, so this line is the only feedback that
    /// the control did anything.
    var explanation: String {
        switch self {
        case .standard: NSLocalizedString("share.format.standard.detail", comment: "Standard format detail")
        case .obsidian: NSLocalizedString("share.format.obsidian.detail", comment: "Obsidian format detail")
        }
    }

    var isObsidianStyle: Bool { self == .obsidian }
}

@MainActor
struct MeetingShareSelection {
    struct ExportItem: Equatable {
        let suggestedName: String
        let markdown: String
    }

    static let combinedSeparator = "\n\n---\n\n"

    let meeting: Meeting
    var selectedSummaryIDs: Set<UUID>
    var selectedRecordingIDs: Set<UUID>
    var format: MeetingShareFormat = .standard

    /// Defaults to every transcribed recording plus the summary currently
    /// shown on screen, matching the export this replaces.
    init(meeting: Meeting, preselectedSummary: Summary?) {
        self.meeting = meeting
        selectedSummaryIDs = preselectedSummary.map { [$0.id] } ?? []
        selectedRecordingIDs = Set(Self.transcribedRecordings(in: meeting).map(\.recording.id))
    }

    var sortedSummaries: [Summary] {
        meeting.summaries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Recordings with a transcript, numbered by their position among all of
    /// the meeting's recordings so "Recording N" matches the Recordings tab.
    var transcribedRecordings: [(index: Int, recording: Recording)] {
        Self.transcribedRecordings(in: meeting)
    }

    private static func transcribedRecordings(in meeting: Meeting) -> [(index: Int, recording: Recording)] {
        meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .enumerated()
            .filter { $0.element.isReadyForConsumption && $0.element.transcript != nil }
            .map { (index: $0.offset, recording: $0.element) }
    }

    var selectionCount: Int { selectedSummaryIDs.count + selectedRecordingIDs.count }

    var hasSelection: Bool { selectionCount > 0 }

    /// "Share" alone while nothing is selected, "Share (3)" otherwise. The
    /// count is parenthesised rather than written into the sentence so it
    /// needs no plural handling in any of the seven localizations.
    var shareButtonTitle: String {
        let share = NSLocalizedString("share.share_action", comment: "Share")
        return selectionCount > 0 ? "\(share) (\(selectionCount))" : share
    }

    func isSelected(_ summary: Summary) -> Bool { selectedSummaryIDs.contains(summary.id) }

    func isSelected(_ recording: Recording) -> Bool { selectedRecordingIDs.contains(recording.id) }

    mutating func toggle(_ summary: Summary) {
        if selectedSummaryIDs.contains(summary.id) {
            selectedSummaryIDs.remove(summary.id)
        } else {
            selectedSummaryIDs.insert(summary.id)
        }
    }

    mutating func toggle(_ recording: Recording) {
        if selectedRecordingIDs.contains(recording.id) {
            selectedRecordingIDs.remove(recording.id)
        } else {
            selectedRecordingIDs.insert(recording.id)
        }
    }

    static func summaryTitle(for summary: Summary) -> String {
        let name = summary.templateName?.isEmpty == false
            ? summary.templateName!
            : NSLocalizedString("detail.summary.untitled", comment: "Summary")
        return "\(name) · \(summary.createdAt.shortTime)"
    }

    static func transcriptTitle(index: Int) -> String {
        String(format: NSLocalizedString("detail.recording_n", comment: ""), index + 1)
    }

    func markdown(for summary: Summary) -> String {
        MeetingExport.summaryMarkdown(for: meeting, summary: summary, obsidianStyle: format.isObsidianStyle)
    }

    func markdown(for recording: Recording) -> String {
        MeetingExport.transcriptMarkdown(for: meeting, recording: recording, obsidianStyle: format.isObsidianStyle)
    }

    /// One export per selected item — summaries first (newest first), then
    /// transcripts in recording order — each with the file name the share
    /// sheet should suggest for it.
    func exportItems() -> [ExportItem] {
        var items: [ExportItem] = []
        for summary in sortedSummaries where selectedSummaryIDs.contains(summary.id) {
            let name = "\(meeting.title)-summary-\(summary.templateName ?? "\(items.count + 1)")"
            items.append(ExportItem(suggestedName: name, markdown: markdown(for: summary)))
        }
        for entry in transcribedRecordings where selectedRecordingIDs.contains(entry.recording.id) {
            let name = "\(meeting.title)-transcript-\(entry.index + 1)"
            items.append(ExportItem(suggestedName: name, markdown: markdown(for: entry.recording)))
        }
        return items
    }

    /// Every selected export joined into a single clipboard payload; empty
    /// when nothing is selected.
    func combinedMarkdown() -> String {
        exportItems().map(\.markdown).joined(separator: Self.combinedSeparator)
    }
}

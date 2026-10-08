//
//  MeetingShareSelection.swift
//  Kurn
//
//  Selection state and export planning behind `MeetingShareSelectionView`:
//  which summaries/transcripts are picked, in which format, and what
//  documents (and file names) that selection turns into. The view owns only
//  the side effects — pasteboard, temporary files, dismissal.
//

import Foundation
import KurnCore

/// One file the share sheet will produce: a document, the format to render
/// it in, and the name to suggest for it. Kept outside the main-actor
/// `MeetingShareSelection` so rendering and writing can run in the background.
struct MeetingExportItem: Equatable, Sendable {
    let suggestedName: String
    let document: ExportDocument
    let format: MeetingExportFormat

    /// Markdown in the selected flavour, whatever the file format.
    var markdown: String {
        MarkdownExportRenderer.render(document, obsidianStyle: format.isObsidianStyle)
    }

    var clipboardText: String { format.clipboardText(for: document) }

    /// Renders the file and writes it to a protected temporary location.
    /// Nonisolated so the share sheet can do it off the main actor.
    func writeTemporaryFile(pageSize: ExportPageSize) throws -> URL {
        try MeetingExport.temporaryFile(
            data: format.data(for: document, pageSize: pageSize),
            suggestedName: suggestedName,
            fileExtension: format.fileExtension
        )
    }
}

@MainActor
struct MeetingShareSelection {
    typealias ExportItem = MeetingExportItem

    static let combinedSeparator = "\n\n---\n\n"

    let meeting: Meeting
    var selectedSummaryIDs: Set<UUID>
    var selectedRecordingIDs: Set<UUID>
    var format: MeetingExportFormat = .standard

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

    /// What a row's Copy button puts on the clipboard in the current format.
    func clipboardText(for summary: Summary) -> String {
        format.clipboardText(for: MeetingExport.summaryDocument(for: meeting, summary: summary))
    }

    func clipboardText(for recording: Recording) -> String {
        format.clipboardText(for: MeetingExport.transcriptDocument(for: meeting, recording: recording))
    }

    /// One export per selected item — summaries first (newest first), then
    /// transcripts in recording order — each with the file name the share
    /// sheet should suggest for it.
    func exportItems() -> [ExportItem] {
        var items: [ExportItem] = []
        for summary in sortedSummaries where selectedSummaryIDs.contains(summary.id) {
            let name = "\(meeting.title)-summary-\(summary.templateName ?? "\(items.count + 1)")"
            let document = MeetingExport.summaryDocument(for: meeting, summary: summary)
            items.append(ExportItem(suggestedName: name, document: document, format: format))
        }
        for entry in transcribedRecordings where selectedRecordingIDs.contains(entry.recording.id) {
            let name = "\(meeting.title)-transcript-\(entry.index + 1)"
            let document = MeetingExport.transcriptDocument(for: meeting, recording: entry.recording)
            items.append(ExportItem(suggestedName: name, document: document, format: format))
        }
        return items
    }

    /// Every selected export joined into a single clipboard payload; empty
    /// when nothing is selected.
    func combinedClipboardText() -> String {
        exportItems().map(\.clipboardText).joined(separator: Self.combinedSeparator)
    }
}

//
//  MeetingBulkExport.swift
//  Kurn
//
//  Export planning behind `MeetingBulkExportView`: several meetings' latest
//  summaries and/or transcripts, either as one file per meeting (an Obsidian
//  vault wants one note each) or merged into a single file grouped by meeting
//  (one PDF to read or send). The view owns only the side effects — writing
//  the files, the pasteboard, dismissal.
//

import Foundation
import KurnCore

@MainActor
struct MeetingBulkExport {
    enum Grouping: String, CaseIterable, Identifiable {
        case filePerMeeting, singleFile

        var id: String { rawValue }

        var title: String {
            switch self {
            case .filePerMeeting: NSLocalizedString("bulk_export.grouping.per_meeting", comment: "One file per meeting")
            case .singleFile: NSLocalizedString("bulk_export.grouping.single", comment: "Single file")
            }
        }
    }

    /// The selected meetings, oldest first: a combined file reads as a
    /// chronicle, and per-meeting files are named by date anyway.
    let meetings: [Meeting]
    var includesSummaries = true
    var includesTranscripts = true
    var format: MeetingExportFormat = .standard
    var grouping: Grouping = .filePerMeeting

    init(meetings: [Meeting]) {
        self.meetings = meetings.sorted { $0.createdAt < $1.createdAt }
    }

    /// The meetings that have something of what is included — a summary, a
    /// transcript. Those with neither are left out rather than exported as an
    /// empty header.
    var exportableMeetings: [Meeting] {
        meetings.filter { meeting in
            (includesSummaries && meeting.latestSummary != nil)
                || (includesTranscripts && !MeetingExport.transcribedRecordings(of: meeting).isEmpty)
        }
    }

    var canExport: Bool { !exportableMeetings.isEmpty }

    /// "3 of 5 meetings have a summary or transcript to export."
    var availabilityText: String {
        String(
            format: NSLocalizedString("bulk_export.availability", comment: "N of M meetings will be exported"),
            exportableMeetings.count, meetings.count
        )
    }

    /// "Share" alone while nothing can be exported, "Share (3)" with the
    /// number of files otherwise — see `MeetingShareSelection.shareButtonTitle`.
    var shareButtonTitle: String {
        let share = NSLocalizedString("share.share_action", comment: "Share")
        let count = fileCount
        return count > 0 ? "\(share) (\(count))" : share
    }

    /// How many files `exportItems()` will produce, without building them —
    /// the title is read on every render and the documents carry whole
    /// transcripts.
    var fileCount: Int {
        let count = exportableMeetings.count
        guard count > 0 else { return 0 }
        return grouping == .singleFile ? 1 : count
    }

    /// One meeting's document: its notes, its latest summary and/or its
    /// transcripts, as its standalone export would have them.
    func document(for meeting: Meeting) -> ExportDocument {
        MeetingExport.document(
            for: meeting,
            summary: includesSummaries ? meeting.latestSummary : nil,
            includesTranscript: includesTranscripts
        )
    }

    /// Every exportable meeting merged into one document, grouped by meeting.
    func combinedDocument() -> ExportDocument {
        let meetings = exportableMeetings
        let parts = meetings.map(document(for:))
        let labels = parts.first?.labels ?? .english
        let dates = meetings.map(\.createdAt)
        var dateLine = ""
        if let first = dates.min(), let last = dates.max() {
            let start = ExportLanguage.dateLine(for: first, labels: labels)
            let end = ExportLanguage.dateLine(for: last, labels: labels)
            dateLine = start == end ? start : "\(start) – \(end)"
        }
        let title = String(
            format: NSLocalizedString("bulk_export.combined_title", comment: "Title of a multi-meeting export"),
            meetings.count
        )
        return ExportDocument.combining(parts, title: title, dateLine: dateLine)
    }

    /// The files the share sheet will produce.
    func exportItems() -> [MeetingExportItem] {
        let meetings = exportableMeetings
        guard !meetings.isEmpty else { return [] }
        switch grouping {
        case .filePerMeeting:
            return meetings.map { meeting in
                MeetingExportItem(
                    suggestedName: "\(Self.fileDate(meeting.createdAt)) \(meeting.title)",
                    document: document(for: meeting),
                    format: format
                )
            }
        case .singleFile:
            let newest = meetings.map(\.createdAt).max() ?? Date()
            return [MeetingExportItem(
                suggestedName: "Kurn meetings \(Self.fileDate(newest))",
                document: combinedDocument(),
                format: format
            )]
        }
    }

    /// Everything on one clipboard, grouped by meeting, whatever the grouping.
    func clipboardText() -> String {
        guard canExport else { return "" }
        return format.clipboardText(for: combinedDocument())
    }

    /// `yyyy-MM-dd`, so per-meeting files sort by date in Files and in a
    /// vault, and two meetings with the same title never share a name.
    static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

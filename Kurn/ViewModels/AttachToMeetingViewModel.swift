//
//  AttachToMeetingViewModel.swift
//  Kurn
//
//  State for `AttachToMeetingView`, the sheet a PDF shared from another app
//  opens on: the search over meetings, the import in flight, its error, and
//  which meeting the files went into. The use cases themselves are
//  `MeetingAttachmentImporter`'s (`importPDFs`, and `importPDFsIntoNewMeeting`
//  for "New meeting"); this only sequences them and keeps what the view shows.
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class AttachToMeetingViewModel {
    let files: [URL]
    var searchText = ""
    private(set) var isImporting = false
    var error: AppError?
    /// Title of the meeting the files went into, once at least one has.
    private(set) var attachedMeetingTitle: String?

    @ObservationIgnored private let importer: MeetingAttachmentImporter

    init(files: [URL], importer: MeetingAttachmentImporter) {
        self.files = files
        self.importer = importer
    }

    convenience init(files: [URL], modelContext: ModelContext) {
        self.init(files: files, importer: MeetingAttachmentImporter(context: modelContext))
    }

    var isFinished: Bool { attachedMeetingTitle != nil }

    /// The meetings matching the search, in the order given — the same match
    /// the meetings list uses (title, notes, transcript).
    func matchingMeetings(_ meetings: [Meeting]) -> [Meeting] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { $0.matches(search: query) }
    }

    func attach(to meeting: Meeting) async {
        guard !isImporting else { return }
        isImporting = true
        let report = await importer.importPDFs(from: files, into: meeting)
        isImporting = false
        finish(meetingTitle: report.importedCount > 0 ? meeting.title : nil, failure: report.firstFailure)
    }

    func attachToNewMeeting() async {
        guard !isImporting else { return }
        isImporting = true
        let (meeting, report) = await importer.importPDFsIntoNewMeeting(from: files)
        isImporting = false
        finish(meetingTitle: meeting?.title, failure: report.firstFailure)
    }

    private func finish(meetingTitle: String?, failure: AppError?) {
        if let meetingTitle { attachedMeetingTitle = meetingTitle }
        error = failure
    }
}

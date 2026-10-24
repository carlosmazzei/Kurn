//
//  MeetingAttachmentsViewModel.swift
//  Kurn
//
//  State for a meeting's Documents section (`MeetingDetailAttachments`): the
//  Files picker, the Quick Look preview, the import in flight and its error.
//  The view only renders this and forwards taps; importing is
//  `MeetingAttachmentImporter` and deleting is `MeetingLibrary`, both built
//  here from the context the view hands in, so tests drive every branch with
//  an in-memory store and a scripted extractor.
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class MeetingAttachmentsViewModel {
    typealias MakeImporter = @MainActor (ModelContext) -> MeetingAttachmentImporter
    typealias MakeLibrary = @MainActor (ModelContext) -> MeetingLibrary

    var isShowingImporter = false
    /// The file Quick Look shows; `nil` when no preview is open.
    var previewURL: URL?
    private(set) var isImporting = false
    var error: AppError?

    @ObservationIgnored private let makeImporter: MakeImporter
    @ObservationIgnored private let makeLibrary: MakeLibrary

    init(
        makeImporter: @escaping MakeImporter = { MeetingAttachmentImporter(context: $0) },
        makeLibrary: @escaping MakeLibrary = { MeetingLibrary(context: $0) }
    ) {
        self.makeImporter = makeImporter
        self.makeLibrary = makeLibrary
    }

    func requestImport() {
        guard !isImporting else { return }
        isShowingImporter = true
    }

    func preview(_ attachment: MeetingAttachment) {
        previewURL = attachment.fileURL
    }

    /// The Files picker's result: imports the chosen PDFs into `meeting`,
    /// surfacing the first failure. A picker failure is reported the same way.
    func importPicked(_ result: Result<[URL], any Error>, into meeting: Meeting, context: ModelContext) async {
        switch result {
        case .failure(let failure):
            error = .attachmentImportFailed(failure.localizedDescription)
        case .success(let urls):
            guard !urls.isEmpty, !isImporting else { return }
            isImporting = true
            let report = await makeImporter(context).importPDFs(from: urls, into: meeting)
            isImporting = false
            if let failure = report.firstFailure { error = failure }
        }
    }

    /// Deletes `attachment`, closing its preview first when it is the one open.
    func delete(_ attachment: MeetingAttachment, context: ModelContext) {
        if previewURL == attachment.fileURL { previewURL = nil }
        do throws(AppError) {
            try makeLibrary(context).deleteAttachment(attachment)
        } catch {
            self.error = error
        }
    }
}

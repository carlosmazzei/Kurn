//
//  MeetingAttachmentImporter.swift
//  Kurn
//
//  Adds a PDF to a meeting, from either entry point — the meeting's own
//  "Add PDF" (a Files pick) or a file another app shared into Kurn
//  (`IncomingFileInbox`). Three steps, in an order that never leaves half a
//  result behind:
//
//  1. Copy the file into protected storage (`AttachmentFileStore`). The
//     source is never moved or deleted here; the inbox decides what happens
//     to its own copies.
//  2. Read its text off the main actor (`PDFTextExtractor`), under the same
//     resource reservation as photo OCR. This is also the validation: a file
//     PDFKit cannot open, or one locked with a password, is refused and its
//     copy removed.
//  3. Record the attachment (`MeetingLibrary.addAttachment`), which removes
//     the copy itself when the save fails.
//
//  A document with no readable text is still attached — the user can open
//  it from the meeting — it just adds nothing to the prompts.
//

import Foundation
import KurnCore
import SwiftData

@MainActor
struct MeetingAttachmentImporter {
    typealias Extract = @Sendable (URL) -> Result<PDFTextExtraction, PDFTextExtractor.Failure>

    /// Production extraction: PDFKit's text layer plus OCR of scanned pages.
    static let liveExtract: Extract = { url in
        do throws(PDFTextExtractor.Failure) {
            return .success(try PDFTextExtractor.extract(from: url))
        } catch {
            return .failure(error)
        }
    }

    private let library: MeetingLibrary
    private let extract: Extract

    init(context: ModelContext, extract: @escaping Extract = MeetingAttachmentImporter.liveExtract) {
        self.library = MeetingLibrary(context: context)
        self.extract = extract
    }

    /// What `importPDFs` did: how many files were attached, and the first
    /// failure among the others, if any, for the caller to show.
    struct Report {
        var importedCount = 0
        var firstFailure: AppError?
    }

    /// Imports every file in `sources` into `meeting`, carrying on past a
    /// file that fails so one bad file does not cost the others.
    func importPDFs(from sources: [URL], into meeting: Meeting) async -> Report {
        var report = Report()
        for source in sources {
            do throws(AppError) {
                try await importPDF(from: source, into: meeting)
                report.importedCount += 1
            } catch {
                if report.firstFailure == nil { report.firstFailure = error }
            }
        }
        return report
    }

    @discardableResult
    func importPDF(from source: URL, into meeting: Meeting) async throws(AppError) -> MeetingAttachment {
        let operationID = OperationID()
        let startedAt = Date()
        let fileName: String
        do {
            fileName = try AttachmentFileStore.importCopy(of: source, meetingID: meeting.id)
        } catch {
            record(operationID, stage: "copy", outcome: .failed, startedAt: startedAt, code: "copy_failed")
            throw (error as? AppError) ?? .protectedStorageUnavailable(error.localizedDescription)
        }

        let url = AttachmentFileStore.resolveURL(fileName: fileName)
        let extract = self.extract
        let outcome: Result<PDFTextExtraction, PDFTextExtractor.Failure>
        do {
            outcome = try await withResourceReservation(.photoTextRecognition) {
                await Task.detached(priority: .userInitiated) { extract(url) }.value
            }
        } catch {
            AttachmentFileStore.delete(fileName: fileName)
            record(operationID, stage: "extract", outcome: .cancelled, startedAt: startedAt, code: "cancelled")
            throw AppError.attachmentImportFailed(error.localizedDescription)
        }

        switch outcome {
        case .failure(let failure):
            AttachmentFileStore.delete(fileName: fileName)
            record(operationID, stage: "extract", outcome: .failed, startedAt: startedAt, code: Self.code(for: failure))
            throw AppError.attachmentImportFailed(Self.message(for: failure))
        case .success(let extraction):
            let attachment: MeetingAttachment
            do throws(AppError) {
                attachment = try library.addAttachment(
                    to: meeting,
                    fileName: fileName,
                    displayName: Self.displayName(for: source),
                    pageCount: extraction.pageCount,
                    extractedText: extraction.text
                )
            } catch {
                record(operationID, stage: "save", outcome: .failed, startedAt: startedAt, code: error.logCode)
                throw error
            }
            record(
                operationID, stage: "save", outcome: .succeeded, startedAt: startedAt,
                code: extraction.text == nil ? "no_text" : nil
            )
            return attachment
        }
    }

    /// The name shown for an attachment: the file's own name, or a localized
    /// fallback when it has none.
    static func displayName(for source: URL) -> String {
        let name = source.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "/" else {
            return NSLocalizedString("attachment.untitled", comment: "Name of an attached document that has none")
        }
        return name
    }

    static func message(for failure: PDFTextExtractor.Failure) -> String {
        switch failure {
        case .unreadable:
            return NSLocalizedString("attachment.error.unreadable", comment: "The file is not a readable PDF")
        case .locked:
            return NSLocalizedString("attachment.error.locked", comment: "The PDF is protected by a password")
        }
    }

    private static func code(for failure: PDFTextExtractor.Failure) -> String {
        switch failure {
        case .unreadable: return "unreadable"
        case .locked: return "locked"
        }
    }

    private func record(
        _ operationID: OperationID,
        stage: String,
        outcome: ReliabilityEvent.Outcome,
        startedAt: Date,
        code: String?
    ) {
        ReliabilityLog.record(ReliabilityEvent(
            operationID: operationID, operation: "attachment_import", stage: stage,
            outcome: outcome, elapsedSeconds: Date().timeIntervalSince(startedAt), code: code
        ))
    }
}

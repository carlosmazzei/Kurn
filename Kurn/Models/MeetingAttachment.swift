//
//  MeetingAttachment.swift
//  Kurn
//
//  A document attached to a meeting — today always a PDF, picked from Files
//  inside the meeting or shared into the app from another one — kept as
//  reference material next to the recordings and photos. Its extracted text
//  is what makes it useful: `Meeting.assembledContextText()` appends it after
//  the transcript (`AttachmentPromptContext`), so summaries, the wiki, the
//  meeting's chat and generated documents all read it.
//
//  Belongs to the meeting rather than to a recording, unlike `MeetingPhoto`:
//  a photo is a moment on a recording's timeline, a document has no moment.
//  The file lives in the protected recordings directory
//  (`AttachmentFileStore`) and is referenced here by file name only — the
//  same pattern `Recording.fileName` and `MeetingPhoto.fileName` use.
//

import Foundation
import KurnCore
import SwiftData

@Model
final class MeetingAttachment {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    /// File name (not absolute path) within the protected attachments
    /// directory, resolved lazily via `AttachmentFileStore`.
    var fileName: String
    /// The name the file had when it was added, shown in the UI and used as
    /// the document's name in prompts.
    var displayName: String
    var fileSize: Int64
    var pageCount: Int
    /// Text extracted on device when the file was added (`PDFTextExtractor`);
    /// `nil` when the document carries none that could be read.
    var extractedText: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        fileName: String,
        displayName: String,
        fileSize: Int64 = 0,
        pageCount: Int = 0,
        extractedText: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meeting = meeting
        self.fileName = fileName
        self.displayName = displayName
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.extractedText = extractedText
        self.createdAt = createdAt
    }

    /// Absolute URL of the backing file in the current container.
    var fileURL: URL {
        AttachmentFileStore.resolveURL(fileName: fileName)
    }

    /// Whether any text could be read from the document — without it the
    /// attachment is kept but adds nothing to prompts.
    var hasExtractedText: Bool {
        extractedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// "12 pages · 1.4 MB" — the row's secondary line.
    var detailsText: String {
        let pages = pageCount == 1
            ? NSLocalizedString("detail.attachments.one_page", comment: "1 page")
            : String(format: NSLocalizedString("detail.attachments.pages", comment: "N pages"), pageCount)
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        return "\(pages) · \(size)"
    }

    /// This attachment as prompt context.
    var promptDocument: AttachmentPromptContext.Document {
        AttachmentPromptContext.Document(name: displayName, text: extractedText ?? "")
    }
}

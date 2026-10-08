//
//  MeetingExportFormat.swift
//  Kurn
//
//  Every format the share sheet can export a meeting's summaries and
//  transcripts in. All of them render the same `ExportDocument` (see
//  `MeetingExport`), so they differ only in presentation, never in content.
//

import Foundation
import KurnCore

enum MeetingExportFormat: String, CaseIterable, Sendable {
    case standard, obsidian, pdf, docx, html, plainText

    var title: String {
        switch self {
        case .standard: NSLocalizedString("share.format.standard", comment: "Markdown")
        case .obsidian: NSLocalizedString("share.format.obsidian", comment: "Obsidian")
        case .pdf: NSLocalizedString("share.format.pdf", comment: "PDF")
        case .docx: NSLocalizedString("share.format.docx", comment: "Word (.docx)")
        case .html: NSLocalizedString("share.format.html", comment: "Web page (HTML)")
        case .plainText: NSLocalizedString("share.format.plain_text", comment: "Plain text")
        }
    }

    /// What the choice actually changes in the exported file. Without it a
    /// format is just a word in a menu — nothing else on the screen reacts to
    /// the picker, so this line is the only feedback that the control did
    /// anything.
    var explanation: String {
        switch self {
        case .standard: NSLocalizedString("share.format.standard.detail", comment: "Markdown format detail")
        case .obsidian: NSLocalizedString("share.format.obsidian.detail", comment: "Obsidian format detail")
        case .pdf: NSLocalizedString("share.format.pdf.detail", comment: "PDF format detail")
        case .docx: NSLocalizedString("share.format.docx.detail", comment: "Word format detail")
        case .html: NSLocalizedString("share.format.html.detail", comment: "HTML format detail")
        case .plainText: NSLocalizedString("share.format.plain_text.detail", comment: "Plain text format detail")
        }
    }

    var fileExtension: String {
        switch self {
        case .standard, .obsidian: "md"
        case .pdf: "pdf"
        case .docx: "docx"
        case .html: "html"
        case .plainText: "txt"
        }
    }

    var isObsidianStyle: Bool { self == .obsidian }

    /// What Copy puts on the clipboard. The text formats copy themselves;
    /// PDF, Word and HTML are files rather than text, so they copy Markdown —
    /// the form every notes app, chat and editor pastes with its structure.
    func clipboardText(for document: ExportDocument) -> String {
        switch self {
        case .plainText:
            return PlainTextExportRenderer.render(document)
        case .standard, .obsidian, .pdf, .docx, .html:
            return MarkdownExportRenderer.render(document, obsidianStyle: isObsidianStyle)
        }
    }

    /// The exported file's bytes. Nonisolated and pure, so a long meeting's
    /// PDF or Word file renders off the main actor.
    func data(for document: ExportDocument, pageSize: ExportPageSize) throws -> Data {
        switch self {
        case .standard, .obsidian:
            return Data(MarkdownExportRenderer.render(document, obsidianStyle: isObsidianStyle).utf8)
        case .plainText:
            return Data(PlainTextExportRenderer.render(document).utf8)
        case .html:
            return Data(HTMLExportRenderer.render(document).utf8)
        case .docx:
            return try DOCXExportRenderer.render(document, pageSize: pageSize)
        case .pdf:
            return PDFExportRenderer.render(document, pageSize: pageSize)
        }
    }
}

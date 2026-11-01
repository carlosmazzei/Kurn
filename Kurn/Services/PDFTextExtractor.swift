//
//  PDFTextExtractor.swift
//  Kurn
//
//  Reads the text of a PDF attached to a meeting, on device: PDFKit's text
//  layer for every page that has one, and Vision OCR
//  (`PhotoTextRecognizer`) for a page that does not — a scanned handout or a
//  photographed slide exported to PDF is exactly the kind of document that
//  gets attached to a meeting, and has no text layer at all. OCR is bounded
//  to `maxOCRPages` pages, because rendering and recognizing a page takes on
//  the order of a second and a long scan must not hold the import for
//  minutes; the pages past it are simply not read.
//
//  The whole read is bounded too, because the document comes from whoever
//  sent it: a file over `maxFileBytes` is refused before PDFKit opens it,
//  and at most `maxPages` pages and `maxCharacters` characters of text are
//  kept — the rest is dropped and the result says so (`isTruncated`).
//  `maxCharacters` stays well above what `AttachmentPromptContext` lets a
//  document put in a prompt, so the cap never changes what a summary reads.
//
//  Synchronous and blocking: callers run it off the main actor
//  (`MeetingAttachmentImporter`), under a resource reservation.
//

import Foundation
import PDFKit
import UIKit

struct PDFTextExtraction: Equatable, Sendable {
    let pageCount: Int
    /// The document's text, pages separated by a blank line; `nil` when no
    /// page yielded any.
    let text: String?
    /// Whether text was left out because the document passed `maxPages` or
    /// `maxCharacters`.
    var isTruncated = false
}

enum PDFTextExtractor {
    enum Failure: Error, Equatable {
        /// Not a PDF PDFKit can open, or one with no pages.
        case unreadable
        /// Encrypted with a password the app does not have.
        case locked
        /// Larger than `maxFileBytes`; not opened at all.
        case tooLarge
    }

    /// Largest file, in bytes, that is opened at all.
    static let maxFileBytes = 100 * 1_024 * 1_024
    /// Pages read per document at most, text layer or OCR.
    static let maxPages = 1_000
    /// Characters of text kept per document at most.
    static let maxCharacters = 1_000_000

    /// Scanned pages OCR'd per document at most.
    static let maxOCRPages = 20
    /// Longest side, in points, a page is rendered at for OCR.
    static let ocrRenderSide: CGFloat = 2_000

    /// Reads `url`. `recognize` OCRs a rendered page — Vision in production,
    /// a stub in tests, since what Vision reads off a simulator is not
    /// something a test should depend on.
    static func extract(
        from url: URL,
        maxOCRPages: Int = Self.maxOCRPages,
        maxPages: Int = Self.maxPages,
        maxCharacters: Int = Self.maxCharacters,
        maxFileBytes: Int = Self.maxFileBytes,
        recognize: (CGImage) -> String? = PhotoTextRecognizer.recognizeText(in:)
    ) throws(Failure) -> PDFTextExtraction {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileBytes {
            throw Failure.tooLarge
        }
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        guard !document.isLocked else { throw Failure.locked }
        guard document.pageCount > 0 else { throw Failure.unreadable }

        let separator = "\n\n"
        var pages: [String] = []
        var characters = 0
        var ocrBudget = maxOCRPages
        let readablePages = min(document.pageCount, max(maxPages, 0))
        var isTruncated = readablePages < document.pageCount
        for index in 0..<readablePages {
            guard let page = document.page(at: index),
                  let text = pageText(of: page, ocrBudget: &ocrBudget, recognize: recognize) else { continue }
            let gap = pages.isEmpty ? 0 : separator.count
            let remaining = maxCharacters - characters - gap
            guard remaining > 0 else {
                isTruncated = true
                break
            }
            let length = text.count
            if length > remaining {
                pages.append(String(text.prefix(remaining)))
                isTruncated = true
                break
            }
            pages.append(text)
            characters += gap + length
        }
        return PDFTextExtraction(
            pageCount: document.pageCount,
            text: pages.isEmpty ? nil : pages.joined(separator: separator),
            isTruncated: isTruncated
        )
    }

    /// `page`'s text layer, or what OCR reads off it while `ocrBudget` lasts.
    private static func pageText(
        of page: PDFPage,
        ocrBudget: inout Int,
        recognize: (CGImage) -> String?
    ) -> String? {
        if let text = normalized(page.string) { return text }
        guard ocrBudget > 0 else { return nil }
        ocrBudget -= 1
        return render(page).flatMap(recognize).flatMap(normalized)
    }

    /// `text` trimmed, with runs of blank lines collapsed; `nil` when nothing
    /// but whitespace is left.
    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// `page` as an image sized for OCR.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { return nil }
        let scale = ocrRenderSide / longest
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }
}

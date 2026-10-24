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
}

enum PDFTextExtractor {
    enum Failure: Error, Equatable {
        /// Not a PDF PDFKit can open, or one with no pages.
        case unreadable
        /// Encrypted with a password the app does not have.
        case locked
    }

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
        recognize: (CGImage) -> String? = PhotoTextRecognizer.recognizeText(in:)
    ) throws(Failure) -> PDFTextExtraction {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        guard !document.isLocked else { throw Failure.locked }
        guard document.pageCount > 0 else { throw Failure.unreadable }

        var pages: [String] = []
        var ocrBudget = maxOCRPages
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = normalized(page.string) {
                pages.append(text)
            } else if ocrBudget > 0 {
                ocrBudget -= 1
                if let text = render(page).flatMap(recognize).flatMap(normalized) {
                    pages.append(text)
                }
            }
        }
        return PDFTextExtraction(
            pageCount: document.pageCount,
            text: pages.isEmpty ? nil : pages.joined(separator: "\n\n")
        )
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

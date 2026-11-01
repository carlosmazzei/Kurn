//
//  PDFTextExtractorTests.swift
//  KurnTests
//
//  Text extraction from a PDF attached to a meeting, against real documents
//  (`PDFFixtures`): every page's text layer, a page with none, the OCR
//  budget, the page, character and file-size limits, and the refusals — not
//  a PDF, locked by a password, and too large.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct PDFTextExtractorTests {

    @Test func readsTheTextOfEveryPageInOrder() throws {
        let url = try PDFFixtures.makePDF(pages: ["Budget review", "Hiring plan"])
        defer { PDFFixtures.remove(url) }

        let extraction = try PDFTextExtractor.extract(from: url)

        #expect(extraction.pageCount == 2)
        let text = try #require(extraction.text)
        let budget = try #require(text.range(of: "Budget review"))
        let hiring = try #require(text.range(of: "Hiring plan"))
        #expect(budget.upperBound < hiring.lowerBound)
        #expect(text.contains("\n\n"))
        #expect(!extraction.isTruncated)
    }

    @Test func aPageWithNoTextLayerAndNothingToRecognizeYieldsNoText() throws {
        let url = try PDFFixtures.makePDF(pages: [""])
        defer { PDFFixtures.remove(url) }

        let extraction = try PDFTextExtractor.extract(from: url)

        #expect(extraction.pageCount == 1)
        #expect(extraction.text == nil)
    }

    @Test func pagesPastTheOCRBudgetAreNotRecognized() throws {
        let url = try PDFFixtures.makePDF(pages: ["", "Agenda"])
        defer { PDFFixtures.remove(url) }

        let extraction = try PDFTextExtractor.extract(from: url, maxOCRPages: 0)

        #expect(extraction.pageCount == 2)
        #expect(extraction.text?.contains("Agenda") == true)
    }

    @Test func aPageWithoutATextLayerIsRecognizedFromItsImage() throws {
        let url = try PDFFixtures.makePDF(pages: ["Agenda", ""])
        defer { PDFFixtures.remove(url) }
        var renderedPages = 0

        let extraction = try PDFTextExtractor.extract(from: url) { image in
            renderedPages += 1
            #expect(image.width > 0 && image.height > image.width)
            return "  Scanned budget \n\n\n table  "
        }

        #expect(extraction.text == "Agenda\n\nScanned budget\n\ntable")
        // Only the page without a text layer is rendered (portrait, like the page).
        #expect(renderedPages == 1)
    }

    @Test func ocrStopsAtItsPageBudget() throws {
        let url = try PDFFixtures.makePDF(pages: ["", "", ""])
        defer { PDFFixtures.remove(url) }
        var calls = 0

        let extraction = try PDFTextExtractor.extract(from: url, maxOCRPages: 2) { _ in
            calls += 1
            return "page"
        }

        #expect(calls == 2)
        #expect(extraction.text == "page\n\npage")
    }

    @Test func pagesPastThePageLimitAreNotRead() throws {
        let url = try PDFFixtures.makePDF(pages: (1...30).map { "Item-\($0)-end" })
        defer { PDFFixtures.remove(url) }

        let extraction = try PDFTextExtractor.extract(from: url, maxPages: 10)

        #expect(extraction.pageCount == 30)
        #expect(extraction.isTruncated)
        let text = try #require(extraction.text)
        #expect(text.contains("Item-10-end"))
        #expect(!text.contains("Item-11-end"))
        #expect(!text.contains("Item-30-end"))
    }

    @Test func textStopsAtTheCharacterLimitOfAManyPageDocument() throws {
        let line = String(repeating: "budget ", count: 12)
        let url = try PDFFixtures.makePDF(pages: (1...120).map { "Page \($0) \(line)" })
        defer { PDFFixtures.remove(url) }
        let limit = 1_000

        let extraction = try PDFTextExtractor.extract(from: url, maxCharacters: limit)

        #expect(extraction.pageCount == 120)
        #expect(extraction.isTruncated)
        let text = try #require(extraction.text)
        #expect(text.count == limit)
        #expect(text.hasPrefix("Page 1 budget"))
        #expect(!text.contains("Page 120 "))
    }

    @Test func textExactlyAtTheCharacterLimitIsNotTruncated() throws {
        let url = try PDFFixtures.makePDF(pages: ["Agenda"])
        defer { PDFFixtures.remove(url) }

        let extraction = try PDFTextExtractor.extract(from: url, maxCharacters: "Agenda".count)

        #expect(extraction.text == "Agenda")
        #expect(!extraction.isTruncated)
    }

    @Test func aFileOverTheSizeLimitIsRefusedBeforeItIsOpened() throws {
        let url = try PDFFixtures.makePDF(pages: ["Agenda"])
        defer { PDFFixtures.remove(url) }

        #expect(throws: PDFTextExtractor.Failure.tooLarge) {
            try PDFTextExtractor.extract(from: url, maxFileBytes: 16)
        }
    }

    @Test func theDefaultLimitsKeepEverythingAPromptCanUse() {
        #expect(PDFTextExtractor.maxCharacters >= AttachmentPromptContext.maxTotalCharacters)
        #expect(PDFTextExtractor.maxPages >= PDFTextExtractor.maxOCRPages)
        #expect(PDFTextExtractor.maxFileBytes > 0)
    }

    @Test func aFileThatIsNotAPDFIsUnreadable() throws {
        let url = try PDFFixtures.makeNonPDF()
        defer { PDFFixtures.remove(url) }

        #expect(throws: PDFTextExtractor.Failure.unreadable) {
            try PDFTextExtractor.extract(from: url)
        }
    }

    @Test func aMissingFileIsUnreadable() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        #expect(throws: PDFTextExtractor.Failure.unreadable) {
            try PDFTextExtractor.extract(from: url)
        }
    }

    @Test func aPasswordProtectedPDFIsLocked() throws {
        let url = try PDFFixtures.makePDF(pages: ["Confidential"], password: "secret")
        defer { PDFFixtures.remove(url) }

        #expect(throws: PDFTextExtractor.Failure.locked) {
            try PDFTextExtractor.extract(from: url)
        }
    }

    @Test func normalizedTrimsLinesAndCollapsesBlankRuns() {
        #expect(PDFTextExtractor.normalized("\n\n  Title  \n\n\n\n body line \n") == "Title\n\nbody line")
        #expect(PDFTextExtractor.normalized("   \n\t ") == nil)
        #expect(PDFTextExtractor.normalized(nil) == nil)
    }
}

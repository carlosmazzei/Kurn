//
//  PDFTextExtractorTests.swift
//  KurnTests
//
//  Text extraction from a PDF attached to a meeting, against real documents
//  (`PDFFixtures`): every page's text layer, a page with none, the OCR
//  budget, and the two refusals — not a PDF, and locked by a password.
//

import Foundation
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

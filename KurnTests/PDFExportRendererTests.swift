//
//  PDFExportRendererTests.swift
//  KurnTests
//
//  The PDF is checked through PDFKit — page count, page size, extractable
//  text, document title — rather than byte comparison, since Core Text's
//  output is free to change between OS releases.
//

import Foundation
import KurnCore
import PDFKit
import Testing
@testable import Kurn

@MainActor
struct PDFExportRendererTests {

    private func document(blocks: [ExportDocument.Block]) -> ExportDocument {
        ExportDocument(
            title: "Sprint Planning",
            dateLine: "8 Oct 2026",
            duration: "12:34",
            properties: ExportDocument.Properties(date: Date(timeIntervalSince1970: 0), tags: ["weekly"]),
            blocks: blocks
        )
    }

    @Test func rendersAReadablePDFWithTheDocumentsText() throws {
        let data = PDFExportRenderer.render(
            document(blocks: [
                .heading(level: 2, text: "Summary"),
                .markdown("We **decided** to ship.\n\n- [x] Write tests\n- Review"),
                .utterance(ExportDocument.Utterance(timestamp: "0:05", speaker: "Ana", text: "Hello there"))
            ]),
            pageSize: .a4
        )
        #expect(data.starts(with: Data("%PDF".utf8)))

        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)
        let text = try #require(pdf.string)
        #expect(text.contains("Sprint Planning"))
        #expect(text.contains("decided"))
        // Rendered, not transcribed: no Markdown syntax survives.
        #expect(!text.contains("**"))
        #expect(text.contains("Hello there"))
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Sprint Planning")
    }

    @Test func paginatesLongDocuments() throws {
        let lines = (0..<400).map {
            ExportDocument.Block.utterance(ExportDocument.Utterance(
                timestamp: "\($0):00", speaker: "Speaker 1", text: "Line number \($0) of a long meeting transcript."
            ))
        }
        let data = PDFExportRenderer.render(document(blocks: lines), pageSize: .letter)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 5)
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 612) < 1)
        #expect(abs(bounds.height - 792) < 1)
        // The last line made it onto the last page: nothing was truncated.
        let lastPage = try #require(pdf.page(at: pdf.pageCount - 1)?.string)
        #expect(lastPage.contains("Line number 399"))
    }

    @Test func emptyDocumentStillHasOnePage() throws {
        let data = PDFExportRenderer.render(document(blocks: []), pageSize: .a4)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)
    }

    @Test func rendersEveryRichBlockKind() throws {
        let markdown = """
        #### Detail
        Paragraph with `code` and ~~gone~~ and _soft_.
        1. First
        > Quoted
        ```
        let x = 1
        ```
        | A | B |
        |---|---|
        | 1 | 2 |
        ---
        """
        let data = PDFExportRenderer.render(document(blocks: [.markdown(markdown), .photo(timestamp: "0:09", recognizedText: "Whiteboard")]), pageSize: .a4)
        let text = try #require(PDFDocument(data: data)?.string)
        for fragment in ["Detail", "code", "First", "Quoted", "let x = 1", "Whiteboard"] {
            #expect(text.contains(fragment), "missing \(fragment)")
        }
    }
}

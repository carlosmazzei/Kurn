//
//  MeetingExportFormatTests.swift
//  KurnTests
//
//  Each format's bytes start the way its consumers sniff them, and the
//  file extensions match what the share sheet and receiving apps expect.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct MeetingExportFormatTests {

    private let document = ExportDocument(
        title: "Sprint Planning",
        dateLine: "8 Oct 2026",
        properties: ExportDocument.Properties(date: Date(timeIntervalSince1970: 0)),
        blocks: [.heading(level: 2, text: "Summary"), .markdown("We **decided** to ship.")]
    )

    @Test func fileExtensions() {
        #expect(MeetingExportFormat.allCases.map(\.fileExtension) == ["md", "md", "pdf", "docx", "html", "txt"])
    }

    @Test func dataStartsWithEachFormatsSignature() throws {
        func prefix(_ format: MeetingExportFormat, _ count: Int) throws -> String {
            let data = try format.data(for: document, pageSize: .a4)
            return String(decoding: data.prefix(count), as: UTF8.self)
        }
        #expect(try prefix(.standard, 17) == "# Sprint Planning")
        #expect(try prefix(.obsidian, 4) == "---\n")
        #expect(try prefix(.pdf, 4) == "%PDF")
        #expect(try prefix(.docx, 2) == "PK")
        #expect(try prefix(.html, 15) == "<!DOCTYPE html>")
        #expect(try prefix(.plainText, 15) == "Sprint Planning")
    }

    @Test func richFormatsRenderMarkdownInsteadOfCopyingIt() throws {
        let html = String(decoding: try MeetingExportFormat.html.data(for: document, pageSize: .a4), as: UTF8.self)
        #expect(html.contains("<strong>decided</strong>"))
        let text = String(decoding: try MeetingExportFormat.plainText.data(for: document, pageSize: .a4), as: UTF8.self)
        #expect(text.contains("We decided to ship."))
    }

    @Test func clipboardTextIsMarkdownExceptForPlainText() {
        #expect(MeetingExportFormat.html.clipboardText(for: document).contains("We **decided** to ship."))
        #expect(MeetingExportFormat.obsidian.clipboardText(for: document).hasPrefix("---\n"))
        #expect(MeetingExportFormat.plainText.clipboardText(for: document).contains("We decided to ship."))
    }

    @Test func fileNamesAreSanitizedPerExtension() {
        #expect(MeetingExport.fileName(for: "Q&A: Review?", fileExtension: "pdf") == "Q-A-Review.pdf")
        #expect(MeetingExport.fileName(for: "###", fileExtension: "docx") == "meeting.docx")
    }
}

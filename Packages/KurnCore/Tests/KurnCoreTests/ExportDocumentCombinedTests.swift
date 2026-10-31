//
//  ExportDocumentCombinedTests.swift
//  KurnCoreTests
//

import Foundation
import Testing
@testable import KurnCore

struct ExportDocumentCombinedTests {

    private func part(
        _ title: String,
        at seconds: TimeInterval,
        tags: [String] = [],
        duration: String? = nil,
        labels: ExportLabels = .english
    ) -> ExportDocument {
        ExportDocument(
            title: title,
            dateLine: "Day \(Int(seconds))",
            duration: duration,
            properties: .init(date: Date(timeIntervalSince1970: seconds), tags: tags),
            labels: labels,
            blocks: [.heading(level: 2, text: labels.summary), .bulletItems(["\(title) item"])]
        )
    }

    @Test func eachPartBecomesATopLevelSectionInOrder() {
        let combined = ExportDocument.combining(
            [part("Kickoff", at: 10, duration: "5:00"), part("Retro", at: 20)],
            title: "Meetings",
            dateLine: "Day 10 – Day 20"
        )
        #expect(combined.title == "Meetings")
        #expect(combined.dateLine == "Day 10 – Day 20")
        #expect(combined.duration == nil)
        #expect(combined.blocks == [
            .heading(level: 1, text: "Kickoff"),
            .markdown("_Day 10_ · **Duration:** 5:00"),
            .heading(level: 2, text: "Summary"),
            .bulletItems(["Kickoff item"]),
            .heading(level: 1, text: "Retro"),
            .markdown("_Day 20_"),
            .heading(level: 2, text: "Summary"),
            .bulletItems(["Retro item"])
        ])
    }

    @Test func propertiesUnionTagsAndTakeTheEarliestDate() {
        let combined = ExportDocument.combining(
            [part("B", at: 50, tags: ["ops", "q3"]), part("A", at: 5, tags: ["q3", "hiring"])],
            title: "All",
            dateLine: ""
        )
        #expect(combined.properties.tags == ["ops", "q3", "hiring"])
        #expect(combined.properties.date == Date(timeIntervalSince1970: 5))
        #expect(combined.properties.folderPath == nil)
        #expect(!combined.properties.isFavorite)
    }

    @Test func labelsComeFromTheFirstPart() {
        let portuguese = ExportLabels.forLanguage("pt")
        let combined = ExportDocument.combining(
            [part("Reunião", at: 1, duration: "1:00", labels: portuguese), part("Meeting", at: 2)],
            title: "All",
            dateLine: ""
        )
        #expect(combined.labels == portuguese)
        #expect(combined.blocks[1] == .markdown("_Day 1_ · **Duração:** 1:00"))
        // A part's own headings stay in its own language.
        #expect(combined.blocks[6] == .heading(level: 2, text: "Summary"))
    }

    @Test func noPartsIsAnEmptyEnglishDocument() {
        let combined = ExportDocument.combining([], title: "Empty", dateLine: "")
        #expect(combined.blocks.isEmpty)
        #expect(combined.labels == .english)
        #expect(combined.properties.tags.isEmpty)
    }

    @Test func everyFormatRendersEveryPart() throws {
        let combined = ExportDocument.combining([part("Kickoff", at: 10), part("Retro", at: 20)], title: "All", dateLine: "")
        let markdown = MarkdownExportRenderer.render(combined)
        #expect(markdown.contains("# Kickoff\n"))
        #expect(markdown.contains("# Retro\n"))
        let html = HTMLExportRenderer.render(combined)
        #expect(html.contains("Kickoff item"))
        #expect(html.contains("Retro item"))
        let text = PlainTextExportRenderer.render(combined)
        #expect(text.contains("Retro item"))
    }
}

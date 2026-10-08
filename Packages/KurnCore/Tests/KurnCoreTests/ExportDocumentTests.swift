//
//  ExportDocumentTests.swift
//  KurnCoreTests
//
//  The rich layer every non-Markdown export renders: summary Markdown and
//  items expanded into styled blocks, transcript lines into styled runs.
//

import Testing
@testable import KurnCore

struct ExportDocumentTests {

    private func document(_ blocks: [ExportDocument.Block]) -> ExportDocument {
        ExportDocument(title: "T", dateLine: "D", properties: .init(date: .init(timeIntervalSince1970: 0)), blocks: blocks)
    }

    @Test func summaryItemsBecomeListItemsWithTaskBoxes() {
        let blocks = document([.bulletItems(["Ship", "[ ] Call Bob", "- **Done**"])]).richBlocks
        #expect(blocks == [
            .listItem(indent: 0, marker: .bullet, runs: [InlineRun("Ship")]),
            .listItem(indent: 0, marker: .task(checked: false), runs: [InlineRun("Call Bob")]),
            .listItem(indent: 0, marker: .bullet, runs: [InlineRun("Done", style: .bold)])
        ])
    }

    @Test func bodyHeadingsNestBelowTheSectionTitle() {
        let blocks = document([.markdown("# Top\nText")]).richBlocks
        #expect(blocks == [
            .heading(level: 4, runs: [InlineRun("Top")]),
            .paragraph(runs: [InlineRun("Text")])
        ])
    }

    @Test func documentHeadingsKeepTheirLevel() {
        #expect(document([.heading(level: 2, text: "Summary")]).richBlocks == [.heading(level: 2, runs: [InlineRun("Summary")])])
    }

    @Test func quotesTablesCodeAndRules() {
        let markdown = "> quoted\n\n```\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---"
        #expect(document([.markdown(markdown)]).richBlocks == [
            .quote(runs: [InlineRun("quoted")]),
            .code("let x = 1"),
            .table(headers: [[InlineRun("A")], [InlineRun("B")]], rows: [[[InlineRun("1")], [InlineRun("2")]]]),
            .rule
        ])
    }

    @Test func notesAreNotParsedAsMarkdown() {
        #expect(document([.plainText("2 * 3 **not bold**")]).richBlocks == [.paragraph(runs: [InlineRun("2 * 3 **not bold**")])])
    }

    @Test func utterancesAndPhotos() {
        let utterance = ExportDocument.Utterance(timestamp: "0:05", speaker: "Ana", text: "Hi *there*", isHighlighted: true)
        #expect(document([.utterance(utterance)]).richBlocks == [.paragraph(runs: [
            InlineRun("⭐ "), InlineRun("[0:05] Ana:", style: .bold), InlineRun(" Hi *there*")
        ])])
        #expect(document([.photo(timestamp: "0:09", recognizedText: "Board")]).richBlocks == [
            .paragraph(runs: [InlineRun("📷 [0:09] Board", style: .italic)])
        ])
        #expect(document([.photo(timestamp: "0:09", recognizedText: nil)]).richBlocks == [
            .paragraph(runs: [InlineRun("📷 [0:09]", style: .italic)])
        ])
    }

    @Test func pageSizeFollowsRegion() {
        #expect(ExportPageSize.preferred(forRegion: "us") == .letter)
        #expect(ExportPageSize.preferred(forRegion: "BR") == .a4)
        #expect(ExportPageSize.preferred(forRegion: nil) == .a4)
        #expect(ExportPageSize.a4.twips.width == 11906)
        #expect(ExportPageSize.letter.points.height == 792)
    }
}

//
//  ExportRendererTests.swift
//  KurnCoreTests
//
//  The text-based export renderers: Markdown (plain and Obsidian), plain
//  text and HTML. The binary Word format has its own suite.
//

import Foundation
import Testing
@testable import KurnCore

struct ExportRendererTests {

    private static func localNoon() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
    }

    private func sample(blocks: [ExportDocument.Block], duration: String? = nil) -> ExportDocument {
        ExportDocument(
            title: "Sprint",
            dateLine: "Today",
            duration: duration,
            properties: ExportDocument.Properties(date: Self.localNoon()),
            blocks: blocks
        )
    }

    // MARK: - Markdown

    @Test func markdownEmitsSummaryMarkdownVerbatim() {
        let document = sample(
            blocks: [.heading(level: 2, text: "Summary"), .markdown("We **won**.\n\n- a"), .bulletItems(["x", "y"])],
            duration: "1:00"
        )
        #expect(MarkdownExportRenderer.render(document) == """
        # Sprint

        _Today_

        **Duration:** 1:00

        ## Summary

        We **won**.

        - a

        - x
        - y


        """)
    }

    @Test func obsidianAddsFrontmatterAndWikilinks() {
        var document = sample(blocks: [
            .utterance(ExportDocument.Utterance(timestamp: "0:01", speaker: "Ana", text: "Hi")),
            .photo(timestamp: "0:02", recognizedText: "Board")
        ])
        document.title = "Say \"hi\""
        document.properties.tags = ["weekly", "q3"]
        document.properties.folderPath = "Product/Roadmap"
        document.properties.isFavorite = true

        let expected = "---\ntitle: \"Say \\\"hi\\\"\"\ndate: 2026-10-08\ntags: [\"weekly\", \"q3\"]\n"
            + "folder: \"Product/Roadmap\"\nfavorite: true\n---\n\n"
            + "# Say \"hi\"\n\n_Today_\n\n**[0:01] [[Ana]]:** Hi\n\n📷 [0:02] Board\n\n"
        #expect(MarkdownExportRenderer.render(document, obsidianStyle: true) == expected)
    }

    @Test func frontmatterOmitsAbsentProperties() {
        let frontmatter = MarkdownExportRenderer.frontmatter(for: sample(blocks: []))
        #expect(frontmatter == "---\ntitle: \"Sprint\"\ndate: 2026-10-08\n---\n\n")
    }

    // MARK: - Plain text

    @Test func plainTextDropsMarkdownSyntax() {
        let document = sample(blocks: [.heading(level: 2, text: "Summary"), .markdown("We **won**.\n\n- a\n- [x] b\n\nAfter")])
        #expect(PlainTextExportRenderer.render(document)
            == "Sprint\n======\n\nToday\n\nSummary\n-------\n\nWe won.\n\n• a\n☑ b\n\nAfter\n")
    }

    @Test func plainTextRendersTranscriptLines() {
        let document = sample(
            blocks: [.utterance(ExportDocument.Utterance(timestamp: "0:05", speaker: "Ana", text: "Hello", isHighlighted: true))],
            duration: "0:10"
        )
        let text = PlainTextExportRenderer.render(document)
        #expect(text.contains("Duration: 0:10"))
        #expect(text.contains("⭐ [0:05] Ana: Hello"))
    }

    @Test func plainTextLayoutsOtherBlocks() {
        let markdown = "> q\n\n```\ncode\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---\n\n#### Deep\n\n  - nested\n3. third"
        let text = PlainTextExportRenderer.render(sample(blocks: [.markdown(markdown)]))
        #expect(text.contains("> q"))
        #expect(text.contains("    code"))
        #expect(text.contains("A | B\n1 | 2"))
        #expect(text.contains("————"))
        #expect(text.contains("Deep\n\n"))
        #expect(text.contains("  • nested"))
        #expect(text.contains("3. third"))
    }

    // MARK: - HTML

    @Test func htmlRendersFormattingAndEscapesEverything() {
        var document = sample(blocks: [
            .heading(level: 2, text: "Summary"),
            .markdown("We **won** & <b>more</b>. [click](https://evil.example/?t=secret)\n\n- one\n- two\n\nAfter")
        ], duration: "1:00")
        document.title = "<script>alert(1)</script>"
        document.properties.tags = ["weekly"]
        let html = HTMLExportRenderer.render(document)

        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<title>&lt;script&gt;alert(1)&lt;/script&gt;</title>"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("<h2>Summary</h2>"))
        #expect(html.contains("<strong>won</strong> &amp; &lt;b&gt;more&lt;/b&gt;. click"))
        #expect(!html.contains("evil.example"))
        #expect(!html.contains("href"))
        #expect(html.contains("<span class=\"tag\">weekly</span>"))
        #expect(html.components(separatedBy: "<li").count - 1 == 2)
        #expect(html.contains("</ul>\n<p>After</p>"))
    }

    @Test func htmlRendersEveryBlockKind() {
        let html = HTMLExportRenderer.render(sample(blocks: [
            .markdown("> q\n\n```\na < b\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---\n\n  - nested `x` ~~y~~ *z*"),
            .plainText("line one\nline two")
        ]))
        #expect(html.contains("<blockquote><p>q</p></blockquote>"))
        #expect(html.contains("<pre><code>a &lt; b</code></pre>"))
        #expect(html.contains("<th>A</th><th>B</th>"))
        #expect(html.contains("<td>1</td><td>2</td>"))
        #expect(html.contains("<hr>"))
        #expect(html.contains("margin-left: 1.5rem"))
        #expect(html.contains("<code>x</code> <del>y</del> <em>z</em>"))
        #expect(html.contains("line one<br>line two"))
    }

    @Test func htmlEscapeCoversQuotes() {
        #expect(HTMLExportRenderer.escape("\"a\" & 'b'") == "&quot;a&quot; &amp; &#39;b&#39;")
    }
}

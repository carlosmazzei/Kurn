//
//  MarkdownBlockParserTests.swift
//  KurnTests
//
//  MarkdownBlockParser turns loosely well-formed LLM markdown into blocks for
//  the summary renderer. It must never fail: unrecognized constructs fall back
//  to paragraphs, fences tolerate a missing closer, and tables tolerate ragged
//  rows. These tests pin down each block type plus those fallbacks.
//

import Testing
@testable import Kurn

struct MarkdownBlockParserTests {

    // MARK: - Headings

    @Test func parsesAllHeadingLevels() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let blocks = MarkdownBlockParser.parse("\(hashes) Title")
            #expect(blocks == [.heading(level: level, text: "Title")])
        }
    }

    @Test func sevenHashesFallBackToParagraph() {
        #expect(MarkdownBlockParser.parse("####### Too deep") == [.paragraph(text: "####### Too deep")])
    }

    @Test func hashWithoutSpaceIsParagraph() {
        #expect(MarkdownBlockParser.parse("#nospace") == [.paragraph(text: "#nospace")])
    }

    // MARK: - Lists

    @Test func parsesBulletMarkers() {
        let blocks = MarkdownBlockParser.parse("- one\n* two\n+ three")
        let expected = MarkdownBlock.list(items: [
            MarkdownListItem(indent: 0, marker: .bullet, text: "one"),
            MarkdownListItem(indent: 0, marker: .bullet, text: "two"),
            MarkdownListItem(indent: 0, marker: .bullet, text: "three")
        ])
        #expect(blocks == [expected])
    }

    @Test func parsesOrderedItemsAndRejectsZero() {
        let blocks = MarkdownBlockParser.parse("1. first\n2. second\n0. not a list")
        #expect(blocks == [
            .list(items: [
                MarkdownListItem(indent: 0, marker: .ordered(number: 1), text: "first"),
                MarkdownListItem(indent: 0, marker: .ordered(number: 2), text: "second")
            ]),
            .paragraph(text: "0. not a list")
        ])
    }

    @Test func parsesTaskCheckboxes() {
        let blocks = MarkdownBlockParser.parse("- [ ] open\n- [x] done\n- [X] also done")
        let expected = MarkdownBlock.list(items: [
            MarkdownListItem(indent: 0, marker: .task(checked: false), text: "open"),
            MarkdownListItem(indent: 0, marker: .task(checked: true), text: "done"),
            MarkdownListItem(indent: 0, marker: .task(checked: true), text: "also done")
        ])
        #expect(blocks == [expected])
    }

    @Test func nestedListIndentLevels() {
        let blocks = MarkdownBlockParser.parse("- top\n  - two spaces\n    - four spaces\n\t- tab")
        guard case .list(let items) = blocks.first else {
            Issue.record("expected a list, got \(blocks)")
            return
        }
        #expect(items.map(\.indent) == [0, 1, 2, 2])
        #expect(items.map(\.text) == ["top", "two spaces", "four spaces", "tab"])
    }

    @Test func deepIndentIsClamped() {
        let blocks = MarkdownBlockParser.parse(String(repeating: " ", count: 40) + "- deep")
        #expect(blocks == [.list(items: [MarkdownListItem(indent: 6, marker: .bullet, text: "deep")])])
    }

    @Test func blankLineEndsListRun() {
        let blocks = MarkdownBlockParser.parse("- one\n\n- two")
        #expect(blocks == [
            .list(items: [MarkdownListItem(indent: 0, marker: .bullet, text: "one")]),
            .list(items: [MarkdownListItem(indent: 0, marker: .bullet, text: "two")])
        ])
    }

    @Test func emphasisLineIsNotABullet() {
        #expect(MarkdownBlockParser.parse("*emphasis*") == [.paragraph(text: "*emphasis*")])
    }

    // MARK: - Blockquotes

    @Test func groupsConsecutiveQuoteLines() {
        let blocks = MarkdownBlockParser.parse("> first\n> second")
        #expect(blocks == [.blockquote(blocks: [
            .paragraph(text: "first"),
            .paragraph(text: "second")
        ])])
    }

    @Test func nestedQuoteAndListInsideQuote() {
        let blocks = MarkdownBlockParser.parse("> outer\n> > inner\n> - item")
        #expect(blocks == [.blockquote(blocks: [
            .paragraph(text: "outer"),
            .blockquote(blocks: [.paragraph(text: "inner")]),
            .list(items: [MarkdownListItem(indent: 0, marker: .bullet, text: "item")])
        ])])
    }

    @Test func quoteDepthIsCapped() {
        let raw = "> " + String(repeating: "> ", count: 6) + "deep"
        let blocks = MarkdownBlockParser.parse(raw)
        // Must terminate and still yield a single tolerant block tree.
        #expect(blocks.count == 1)
        func depth(_ block: MarkdownBlock) -> Int {
            if case .blockquote(let inner) = block {
                return 1 + inner.map(depth).max()!
            }
            return 0
        }
        #expect(depth(blocks[0]) <= 5)
    }

    // MARK: - Code blocks

    @Test func parsesFencedCodeWithLanguage() {
        let blocks = MarkdownBlockParser.parse("```swift\nlet x = 1\nlet y = 2\n```")
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1\nlet y = 2")])
    }

    @Test func parsesFencedCodeWithoutLanguage() {
        let blocks = MarkdownBlockParser.parse("```\nplain\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "plain")])
    }

    @Test func unterminatedFenceConsumesToEnd() {
        let blocks = MarkdownBlockParser.parse("```\nno closer\nstill code")
        #expect(blocks == [.codeBlock(language: nil, code: "no closer\nstill code")])
    }

    @Test func listLookalikesInsideFenceStayCode() {
        let blocks = MarkdownBlockParser.parse("```\n- not a bullet\n# not a heading\n```")
        #expect(blocks == [.codeBlock(language: nil, code: "- not a bullet\n# not a heading")])
    }

    // MARK: - Tables

    @Test func parsesSimpleTable() {
        let blocks = MarkdownBlockParser.parse("| Name | Role |\n| --- | --- |\n| Ana | Dev |\n| Bo | PM |")
        #expect(blocks == [.table(
            headers: ["Name", "Role"],
            rows: [["Ana", "Dev"], ["Bo", "PM"]]
        )])
    }

    @Test func raggedRowsArePaddedAndTruncated() {
        let blocks = MarkdownBlockParser.parse("| A | B |\n|---|---|\n| only |\n| x | y | extra |")
        #expect(blocks == [.table(
            headers: ["A", "B"],
            rows: [["only", ""], ["x", "y"]]
        )])
    }

    @Test func alignmentColonsAreAccepted() {
        let blocks = MarkdownBlockParser.parse("| L | C | R |\n|:---|:---:|---:|\n| a | b | c |")
        #expect(blocks == [.table(
            headers: ["L", "C", "R"],
            rows: [["a", "b", "c"]]
        )])
    }

    @Test func pipesWithoutSeparatorAreParagraphs() {
        let blocks = MarkdownBlockParser.parse("a | b\nplain text")
        #expect(blocks == [.paragraph(text: "a | b"), .paragraph(text: "plain text")])
    }

    // MARK: - Horizontal rules

    @Test func parsesHorizontalRules() {
        for raw in ["---", "***", "___", "- - -", "-----"] {
            #expect(MarkdownBlockParser.parse(raw) == [.horizontalRule], "for \(raw)")
        }
    }

    @Test func twoDashesAreNotARule() {
        #expect(MarkdownBlockParser.parse("--") == [.paragraph(text: "--")])
    }

    // MARK: - taskItem(in:)

    @Test func taskItemDetectsVariants() throws {
        let unchecked = try #require(MarkdownBlockParser.taskItem(in: "[ ] call Bob"))
        #expect(unchecked.checked == false)
        #expect(unchecked.text == "call Bob")

        let dashed = try #require(MarkdownBlockParser.taskItem(in: "- [x] send notes"))
        #expect(dashed.checked == true)
        #expect(dashed.text == "send notes")

        let upper = try #require(MarkdownBlockParser.taskItem(in: "* [X] shipped"))
        #expect(upper.checked == true)
        #expect(upper.text == "shipped")

        #expect(MarkdownBlockParser.taskItem(in: "plain bullet") == nil)
        #expect(MarkdownBlockParser.taskItem(in: "- plain dashed") == nil)
    }

    // MARK: - Whole documents

    @Test func emptyInputYieldsNoBlocks() {
        #expect(MarkdownBlockParser.parse("") == [])
        #expect(MarkdownBlockParser.parse("\n\n  \n") == [])
    }

    @Test func mixedDocumentParsesInOrder() {
        let raw = """
        ## Decisions
        We agreed on the plan.

        - [x] draft spec
          - review notes
        1. ship it

        > Keep it simple.

        | Owner | Task |
        |---|---|
        | Ana | spec |

        ---
        ```swift
        let done = true
        ```
        """
        let blocks = MarkdownBlockParser.parse(raw)
        #expect(blocks == [
            .heading(level: 2, text: "Decisions"),
            .paragraph(text: "We agreed on the plan."),
            .list(items: [
                MarkdownListItem(indent: 0, marker: .task(checked: true), text: "draft spec"),
                MarkdownListItem(indent: 1, marker: .bullet, text: "review notes"),
                MarkdownListItem(indent: 0, marker: .ordered(number: 1), text: "ship it")
            ]),
            .blockquote(blocks: [.paragraph(text: "Keep it simple.")]),
            .table(headers: ["Owner", "Task"], rows: [["Ana", "spec"]]),
            .horizontalRule,
            .codeBlock(language: "swift", code: "let done = true")
        ])
    }
}

//
//  SummaryMarkdownTests.swift
//  KurnCoreTests
//
//  The Markdown summary contract: "## " headings become sections, photo
//  reference lines become timestamps, and malformed replies degrade instead
//  of failing.
//

import Foundation
import Testing
@testable import KurnCore

struct SummaryMarkdownTests {

    @Test func eachSecondLevelHeadingStartsASection() throws {
        let sections = try SummaryMarkdown.sections(from: """
        ## Overview
        We **shipped** it.

        ## Action Items
        - [ ] Ana: QA — Friday
        - [x] Rui: notes
        """)
        #expect(sections.map(\.title) == ["Overview", "Action Items"])
        #expect(sections[0].body == "We **shipped** it.")
        #expect(sections[1].body == "- [ ] Ana: QA — Friday\n- [x] Rui: notes")
        #expect(sections.allSatisfy { $0.items.isEmpty })
    }

    @Test func deeperHeadingsStayInTheBody() throws {
        let sections = try SummaryMarkdown.sections(from: "## Topic\n#### Detail\ntext")
        #expect(sections.count == 1)
        #expect(sections[0].body == "#### Detail\ntext")
    }

    @Test func headingsInsideCodeFencesDoNotSplit() throws {
        let sections = try SummaryMarkdown.sections(from: "## Code\n```\n## not a section\n```")
        #expect(sections.count == 1)
        #expect(sections[0].body == "```\n## not a section\n```")
    }

    @Test func aDocumentTitleAboveTheSectionsIsDropped() throws {
        let sections = try SummaryMarkdown.sections(from: "# Weekly sync\n\n## Decisions\nShip it")
        #expect(sections.map(\.title) == ["Decisions"])
    }

    @Test func textBeforeTheFirstSectionBecomesAnUntitledSection() throws {
        let sections = try SummaryMarkdown.sections(from: "A short intro.\n\n## Decisions\nShip it")
        #expect(sections.map(\.title) == ["", "Decisions"])
        #expect(sections[0].body == "A short intro.")
    }

    @Test func firstLevelHeadingsAreSectionsWhenThereAreNoSecondLevelOnes() throws {
        let sections = try SummaryMarkdown.sections(from: "# A\none\n# B\ntwo")
        #expect(sections.map(\.title) == ["A", "B"])
    }

    @Test func aReplyWithNoHeadingsIsOneUntitledSection() throws {
        let sections = try SummaryMarkdown.sections(from: "Just prose.")
        #expect(sections.count == 1)
        #expect(sections[0].title.isEmpty)
        #expect(sections[0].body == "Just prose.")
    }

    @Test func headingDecorationIsRemovedFromTitles() throws {
        let sections = try SummaryMarkdown.sections(from: "##   **Decisões** ##\nok")
        #expect(sections.first?.title == "Decisões")
    }

    @Test func aHashWithoutASpaceIsNotAHeading() {
        #expect(SummaryMarkdown.heading(in: "##Title") == nil)
        #expect(SummaryMarkdown.heading(in: "    ## indented code") == nil)
        #expect(SummaryMarkdown.heading(in: "## Title")?.level == 2)
    }

    @Test func photoLinesBecomeTimestampsAndLeaveTheBody() throws {
        let sections = try SummaryMarkdown.sections(from: """
        ## Whiteboard
        The Q3 targets were agreed.
        📷 [12:34] [1:02:03]
        """)
        #expect(sections[0].body == "The Q3 targets were agreed.")
        #expect(sections[0].photoTimestamps == [754, 3723])
    }

    @Test func photoLinesAcceptALabelAndAVariationSelector() {
        #expect(SummaryMarkdown.photoReferences(in: "📷 Fotos: 00:05, 00:10") == [5, 10])
        #expect(SummaryMarkdown.photoReferences(in: "📷\u{FE0F} [00:05]") == [5])
    }

    @Test func aSentenceStartingWithTheCameraStaysInTheBody() throws {
        #expect(SummaryMarkdown.photoReferences(in: "📷 The slide at [00:05] showed revenue") == nil)
        let sections = try SummaryMarkdown.sections(from: "## S\n📷 The slide showed revenue")
        #expect(sections[0].body == "📷 The slide showed revenue")
        #expect(sections[0].photoTimestamps.isEmpty)
    }

    @Test func aFenceWrappingTheWholeReplyIsRemoved() throws {
        let sections = try SummaryMarkdown.sections(from: "```markdown\n## T\nbody\n```")
        #expect(sections.map(\.title) == ["T"])
        #expect(sections[0].body == "body")
    }

    @Test func theLegacyJSONShapeIsStillAccepted() throws {
        let sections = try SummaryMarkdown.sections(
            from: #"{"sections":[{"title":"Recap","body":"We shipped it","items":["a"],"photoReferences":["00:07"]}]}"#
        )
        #expect(sections.map(\.title) == ["Recap"])
        #expect(sections[0].items == ["a"])
        #expect(sections[0].photoTimestamps == [7])
    }

    @Test func emptySectionsAreDropped() throws {
        let sections = try SummaryMarkdown.sections(from: "## \n\n## Kept\nx")
        #expect(sections.map(\.title) == ["Kept"])
    }

    @Test func anEmptyReplyIsADecodingError() {
        #expect(throws: AppError.self) { try SummaryMarkdown.sections(from: "  \n ") }
    }
}

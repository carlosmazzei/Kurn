//
//  SummaryDraftPreviewTests.swift
//  KurnCoreTests
//
//  The readable draft shown while a summary's Markdown streams in.
//

import Foundation
import Testing
@testable import KurnCore

struct SummaryDraftPreviewTests {

    private static let markdown = """
    ## Decisions
    We ship on Monday.
    - Ana: QA
    - Rui: notes
    📷 [01:02]

    ## Risks
    Line one
    Line two
    """

    private static let expected = """
    Decisions
    We ship on Monday.
    - Ana: QA
    - Rui: notes

    Risks
    Line one
    Line two
    """

    private func preview(_ fragments: [String]) -> SummaryDraftPreview {
        var preview = SummaryDraftPreview()
        fragments.forEach { preview.add($0) }
        return preview
    }

    @Test func showsTitlesAndTextWithoutHeadingMarkersOrPhotoLines() {
        #expect(preview([Self.markdown]).text == Self.expected)
    }

    @Test func theResultDoesNotDependOnWhereFragmentsSplit() {
        let characters = Self.markdown.map(String.init)
        #expect(preview(characters).text == Self.expected)
        let mid = Self.markdown.index(Self.markdown.startIndex, offsetBy: 37)
        let halves = [String(Self.markdown[..<mid]), String(Self.markdown[mid...])]
        #expect(preview(halves).text == Self.expected)
    }

    @Test func textAppearsAsItArrivesNotWhenTheLineEnds() {
        #expect(preview(["## Deci"]).text == "Deci")
        #expect(preview(["Hello wor"]).text == "Hello wor")
    }

    @Test func aLineStartIsHeldOnlyWhileItCouldBeAMarker() {
        #expect(preview(["#"]).text.isEmpty)
        #expect(preview(["#hashtag"]).text == "#hashtag")
        #expect(preview(["`"]).text.isEmpty)
        #expect(preview(["`code` here"]).text == "`code` here")
    }

    @Test func headingsAreSeparatedByOneBlankLine() {
        #expect(preview(["Intro\n## A\nx\n\n\n## B\ny"]).text == "Intro\n\nA\nx\n\nB\ny")
    }

    @Test func fenceLinesAreHiddenButTheirContentIsShown() {
        #expect(preview(["```markdown\n## T\nbody\n```"]).text == "T\nbody\n")
    }

    @Test func wordsCountOnlyTheVisibleText() {
        // Decisions We ship on Monday Ana QA Rui notes Risks Line one Line two.
        #expect(preview([Self.markdown]).words == 14)
    }

    @Test func nothingVisibleMeansAnEmptyDraft() {
        #expect(preview(["📷 [00:01]\n"]).text.isEmpty)
        #expect(SummaryDraftPreview().words == 0)
    }
}

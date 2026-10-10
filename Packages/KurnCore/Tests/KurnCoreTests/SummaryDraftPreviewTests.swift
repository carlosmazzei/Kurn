//
//  SummaryDraftPreviewTests.swift
//  KurnCoreTests
//
//  The readable draft shown while a summary's JSON streams in.
//

import Foundation
import Testing
@testable import KurnCore

struct SummaryDraftPreviewTests {

    private static let json = #"""
    {"sections":[{"title":"Decisions","body":"We ship on Monday.","items":["Ana: QA","Rui: notes"]},{"title":"Risks","body":"Line one\nLine two"}]}
    """#

    private static let expected = """
    Decisions
    We ship on Monday.
    • Ana: QA
    • Rui: notes

    Risks
    Line one
    Line two

    """

    private func preview(_ fragments: [String]) -> SummaryDraftPreview {
        var preview = SummaryDraftPreview()
        fragments.forEach { preview.add($0) }
        return preview
    }

    @Test func showsTitlesBodiesAndItemsWithoutTheJSON() {
        #expect(preview([Self.json]).text == Self.expected)
    }

    @Test func theResultDoesNotDependOnWhereFragmentsSplit() {
        let characters = Self.json.map(String.init)
        #expect(preview(characters).text == Self.expected)
        let mid = Self.json.index(Self.json.startIndex, offsetBy: 37)
        #expect(preview([String(Self.json[..<mid]), String(Self.json[mid...])]).text == Self.expected)
    }

    @Test func valuesAppearAsTheyArriveNotWhenTheyClose() {
        #expect(preview([#"{"sections":[{"title":"Deci"#]).text == "Deci")
    }

    @Test func keysAndUnknownFieldsAreNeverShown() {
        let text = preview([#"{"sections":[{"title":"T","photoReferences":["01:02"],"extra":{"body":"x"},"body":"B"}]}"#]).text
        #expect(text == "T\nB\n")
    }

    @Test func escapesAreDecodedIncludingSplitUnicodeAndSurrogatePairs() {
        let text = preview([#"{"sections":[{"title":"Say \"hi\" \u00e"#, #"9 \ud83d"#, #"\ude80 a\\b"}]}"#]).text
        #expect(text == "Say \"hi\" é 🚀 a\\b\n")
    }

    @Test func proseAndFencesAroundTheJSONAreIgnored() {
        let text = preview(["Here you go:\n```json\n", #"{"sections":[{"title":"T"}]}"#, "\n```"]).text
        #expect(text == "T\n")
    }

    @Test func wordsCountOnlyTheVisibleText() {
        // Decisions We ship on Monday Ana QA Rui notes Risks Line one Line two.
        #expect(preview([Self.json]).words == 14)
    }

    @Test func nothingVisibleMeansAnEmptyDraft() {
        #expect(preview([#"{"sections":["#]).text.isEmpty)
        #expect(SummaryDraftPreview().words == 0)
    }
}

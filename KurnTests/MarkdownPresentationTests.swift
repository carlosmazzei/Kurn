//
//  MarkdownPresentationTests.swift
//  KurnTests
//

import Foundation
import SwiftUI
import Testing
@testable import Kurn

struct MarkdownPresentationTests {

    @Test func headingFontsStepDownByLevelAndFlattenPastFive() {
        #expect(MarkdownPresentation.headingFont(level: 1) == .title2.bold())
        #expect(MarkdownPresentation.headingFont(level: 2) == .title3.bold())
        #expect(MarkdownPresentation.headingFont(level: 3) == .subheadline.bold())
        #expect(MarkdownPresentation.headingFont(level: 4) == .subheadline.weight(.semibold))
        #expect(MarkdownPresentation.headingFont(level: 5) == .footnote.bold())
        #expect(MarkdownPresentation.headingFont(level: 6) == .footnote.weight(.semibold))
        #expect(MarkdownPresentation.headingFont(level: 9) == MarkdownPresentation.headingFont(level: 6))
        #expect(MarkdownPresentation.headingFont(level: 0) == MarkdownPresentation.headingFont(level: 6))
    }

    @Test func bulletGlyphsCycleEveryThreeIndentLevels() {
        #expect(MarkdownPresentation.bulletGlyph(indent: 0) == "•")
        #expect(MarkdownPresentation.bulletGlyph(indent: 1) == "◦")
        #expect(MarkdownPresentation.bulletGlyph(indent: 2) == "▪")
        #expect(MarkdownPresentation.bulletGlyph(indent: 3) == "•")
        #expect(MarkdownPresentation.bulletGlyph(indent: 4) == "◦")
    }

    @Test func inlineMarkdownIsParsedWhenValid() throws {
        let attributed = try #require(MarkdownPresentation.inlineAttributedString("some **bold** text"))
        #expect(String(attributed.characters) == "some bold text")
        let boldRun = attributed.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(boldRun != nil)
    }

    @Test func plainTextRoundTripsThroughInlineParsing() throws {
        let attributed = try #require(MarkdownPresentation.inlineAttributedString("just words"))
        #expect(String(attributed.characters) == "just words")
    }

    /// LLM output is shaped by whatever was said in the meeting, so a link in
    /// it is never made tappable: its text is kept, its destination dropped.
    @Test func linksInGeneratedTextAreNotTappable() throws {
        let markdown = "See [the notes](https://attacker.example/?q=secret) and <kurn://recording/stop>."
        let attributed = try #require(MarkdownPresentation.inlineAttributedString(markdown))
        let hasLink = attributed.runs.contains { $0.link != nil }
        #expect(!hasLink)
        #expect(String(attributed.characters).contains("the notes"))
        #expect(!String(attributed.characters).contains("attacker.example"))
    }
}

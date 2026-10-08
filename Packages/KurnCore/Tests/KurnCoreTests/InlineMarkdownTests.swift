//
//  InlineMarkdownTests.swift
//  KurnCoreTests
//
//  Inline Markdown resolved into styled runs for the rich export formats.
//  Unmatched delimiters stay text, and links keep only their visible text.
//

import Testing
@testable import KurnCore

struct InlineMarkdownTests {

    @Test func plainTextIsOneUnstyledRun() {
        #expect(InlineMarkdown.runs("Nothing special") == [InlineRun("Nothing special")])
    }

    @Test func strongEmphasisAndStrikethrough() {
        #expect(InlineMarkdown.runs("We **decided** today") == [
            InlineRun("We "), InlineRun("decided", style: .bold), InlineRun(" today")
        ])
        #expect(InlineMarkdown.runs("*it* and _em_") == [
            InlineRun("it", style: .italic), InlineRun(" and "), InlineRun("em", style: .italic)
        ])
        #expect(InlineMarkdown.runs("~~old~~ new") == [
            InlineRun("old", style: .strikethrough), InlineRun(" new")
        ])
        #expect(InlineMarkdown.runs("__bold__") == [InlineRun("bold", style: .bold)])
    }

    @Test func nestedStylesCombine() {
        #expect(InlineMarkdown.runs("**bold _and italic_**") == [
            InlineRun("bold ", style: .bold), InlineRun("and italic", style: [.bold, .italic])
        ])
    }

    @Test func codeSpansAreLiteral() {
        #expect(InlineMarkdown.runs("run `a*b*` now") == [
            InlineRun("run "), InlineRun("a*b*", style: .code), InlineRun(" now")
        ])
    }

    @Test func linksAndImagesKeepOnlyTheirText() {
        #expect(InlineMarkdown.runs("see [the site](https://example.com/?q=secret)") == [InlineRun("see the site")])
        #expect(InlineMarkdown.runs("![diagram](img.png)") == [InlineRun("diagram")])
        #expect(InlineMarkdown.runs("[**bold link**](x)") == [InlineRun("bold link", style: .bold)])
    }

    @Test func citationsAreNotLinks() {
        #expect(InlineMarkdown.runs("Agreed [12:34] to ship") == [InlineRun("Agreed [12:34] to ship")])
    }

    @Test func unmatchedDelimitersStayText() {
        #expect(InlineMarkdown.runs("2 * 3 = 6") == [InlineRun("2 * 3 = 6")])
        #expect(InlineMarkdown.runs("a **b") == [InlineRun("a **b")])
        #expect(InlineMarkdown.runs("an `open code") == [InlineRun("an `open code")])
        #expect(InlineMarkdown.runs("snake_case_name") == [InlineRun("snake_case_name")])
    }

    @Test func backslashEscapesPunctuation() {
        #expect(InlineMarkdown.runs("\\*not italic\\*") == [InlineRun("*not italic*")])
    }

    @Test func plainTextJoinsRuns() {
        #expect(InlineMarkdown.runs("a **b** `c`").plainText == "a b c")
    }

    @Test func deepNestingTerminates() {
        let hostile = String(repeating: "**", count: 200) + "x" + String(repeating: "**", count: 200)
        #expect(InlineMarkdown.runs(hostile).plainText.contains("x"))
    }
}

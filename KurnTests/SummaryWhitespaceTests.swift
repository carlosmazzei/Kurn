//
//  SummaryWhitespaceTests.swift
//  KurnTests
//
//  Guards the fix for summaries that rendered a literal "\n": a model that
//  double-escapes newlines in its JSON produces the two characters backslash + n,
//  which are normalized back to real whitespace on the `Summary.sections` read
//  path so views and export show line breaks instead of "\n".
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SummaryWhitespaceTests {

    // The two literal characters backslash + n, as an LLM double-escape yields.
    private let literalNewline = "\\n"

    @Test func unescapingConvertsLiteralSequences() {
        let input = "line one\(literalNewline)    * Owner: Speaker 1\\tindented"
        let output = input.unescapingLiteralWhitespace()
        #expect(output == "line one\n    * Owner: Speaker 1\tindented")
        #expect(!output.contains(literalNewline))
    }

    @Test func unescapingLeavesCleanTextUntouched() {
        let clean = "just a normal line with a real\nnewline"
        #expect(clean.unescapingLiteralWhitespace() == clean)
    }

    @Test func unescapingShortCircuitsWithoutBackslash() {
        let plain = "no escapes here"
        #expect(plain.unescapingLiteralWhitespace() == plain)
    }

    @Test func sectionNormalizationCleansAllFields() {
        let section = SummarySection(
            title: "Title\(literalNewline)x",
            body: "Body\(literalNewline)second",
            items: ["Ação\(literalNewline)    * Owner: Speaker 1"]
        )
        let normalized = section.normalizedWhitespace()
        #expect(normalized.title == "Title\nx")
        #expect(normalized.body == "Body\nsecond")
        #expect(normalized.items.first == "Ação\n    * Owner: Speaker 1")
    }

    @Test func storedSummaryReadsBackWithRealNewlines() throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        // Persist a section carrying the literal escape, as a bad model response would.
        let summary = Summary(
            meeting: meeting,
            sections: [SummarySection(
                title: "Action Items",
                items: ["[ ] Ação\(literalNewline)    * Owner: Speaker 1\(literalNewline)    * Deadline: Not specified"]
            )],
            provider: .openAI
        )
        context.insert(summary)
        try context.save()

        let item = try #require(summary.sections.first?.items.first)
        #expect(!item.contains(literalNewline))
        #expect(item.contains("\n    * Owner: Speaker 1"))
    }
}

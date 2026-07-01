//
//  SummaryJSONParsingTests.swift
//  KurnTests
//
//  SummaryJSON.parse is the tolerant decoder all LLM providers route their raw
//  text response through; it has to cope with code fences and stray prose since
//  models do not always follow the "JSON only" instruction. The contract is a
//  template-driven list of titled sections.
//

import Testing
@testable import Kurn

struct SummaryJSONParsingTests {

    @Test func parsesPlainJSON() throws {
        let raw = """
        {"sections": [
          {"title": "Overview", "body": "Recap"},
          {"title": "Action Items", "items": ["follow up"]}
        ]}
        """
        let json = try SummaryJSON.parse(raw)
        let sections = json.summarySections
        #expect(sections.count == 2)
        #expect(sections[0].title == "Overview")
        #expect(sections[0].body == "Recap")
        #expect(sections[1].items == ["follow up"])
    }

    @Test func stripsMarkdownCodeFenceWithLanguageTag() throws {
        let raw = """
        ```json
        {"sections": [{"title": "Overview", "body": "Recap"}]}
        ```
        """
        let json = try SummaryJSON.parse(raw)
        #expect(json.summarySections.first?.body == "Recap")
    }

    @Test func stripsPlainMarkdownCodeFence() throws {
        let raw = """
        ```
        {"sections": [{"title": "Overview", "body": "Recap"}]}
        ```
        """
        let json = try SummaryJSON.parse(raw)
        #expect(json.summarySections.first?.title == "Overview")
    }

    @Test func extractsJSONObjectSurroundedByProse() throws {
        let raw = """
        Here is the summary you asked for:
        {"sections": [{"title": "Recap", "body": "All good", "items": ["a"]}]}
        Let me know if you need anything else.
        """
        let json = try SummaryJSON.parse(raw)
        let section = try #require(json.summarySections.first)
        #expect(section.title == "Recap")
        #expect(section.body == "All good")
        #expect(section.items == ["a"])
    }

    @Test func summarySectionsDropsEmptyEntries() throws {
        let raw = """
        {"sections": [
          {"title": "", "body": "", "items": []},
          {"title": "Kept", "body": "x"}
        ]}
        """
        let json = try SummaryJSON.parse(raw)
        let sections = json.summarySections
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Kept")
    }

    @Test func throwsDecodingErrorWhenNoJSONObjectPresent() {
        #expect(throws: AppError.self) {
            try SummaryJSON.parse("no json here at all")
        }
    }

    @Test func throwsDecodingErrorOnMalformedJSONObject() {
        #expect(throws: AppError.self) {
            try SummaryJSON.parse("{\"sections\": [ this is not valid }")
        }
    }

    @Test func throwsDecodingErrorOnTruncatedJSON() {
        // A generation cut off by the output-token cap ends mid-structure; the
        // parser must fail cleanly rather than return a partial summary.
        let raw = """
        {"sections": [
          {"title": "Overview", "body": "Recap"},
          {"title": "Action Items", "items": ["follow up", "sche
        """
        #expect(throws: AppError.self) {
            try SummaryJSON.parse(raw)
        }
    }
}

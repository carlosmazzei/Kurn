//
//  SummaryJSONParsingTests.swift
//  MeetSyncTests
//
//  SummaryJSON.parse is the tolerant decoder both LLM providers route their raw
//  text response through; it has to cope with code fences and stray prose since
//  models do not always follow the "JSON only" instruction.
//

import Testing
@testable import MeetSync

struct SummaryJSONParsingTests {

    @Test func parsesPlainJSON() throws {
        let raw = """
        {"summary": "Recap", "actionItems": ["follow up"], "keyDecisions": ["ship it"]}
        """
        let json = try SummaryJSON.parse(raw)
        #expect(json.summary == "Recap")
        #expect(json.actionItems == ["follow up"])
        #expect(json.keyDecisions == ["ship it"])
    }

    @Test func stripsMarkdownCodeFenceWithLanguageTag() throws {
        let raw = """
        ```json
        {"summary": "Recap", "actionItems": [], "keyDecisions": []}
        ```
        """
        let json = try SummaryJSON.parse(raw)
        #expect(json.summary == "Recap")
    }

    @Test func stripsPlainMarkdownCodeFence() throws {
        let raw = """
        ```
        {"summary": "Recap", "actionItems": [], "keyDecisions": []}
        ```
        """
        let json = try SummaryJSON.parse(raw)
        #expect(json.summary == "Recap")
    }

    @Test func extractsJSONObjectSurroundedByProse() throws {
        let raw = """
        Here is the summary you asked for:
        {"summary": "Recap", "actionItems": ["a"], "keyDecisions": ["b"]}
        Let me know if you need anything else.
        """
        let json = try SummaryJSON.parse(raw)
        #expect(json.summary == "Recap")
        #expect(json.actionItems == ["a"])
        #expect(json.keyDecisions == ["b"])
    }

    @Test func throwsDecodingErrorWhenNoJSONObjectPresent() {
        #expect(throws: AppError.self) {
            try SummaryJSON.parse("no json here at all")
        }
    }

    @Test func throwsDecodingErrorOnMalformedJSONObject() {
        #expect(throws: AppError.self) {
            try SummaryJSON.parse("{\"summary\": \"Recap\", this is not valid}")
        }
    }
}

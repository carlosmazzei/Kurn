//
//  SummarySectionTests.swift
//  KurnCoreTests
//
//  Summaries come back from a model as JSON, and some models escape their
//  own newlines ("\\n" as two characters). `normalizedWhitespace` turns
//  those back into real line breaks; summaries stored before photo
//  timestamps existed must still decode.
//

import Foundation
import Testing
@testable import KurnCore

struct SummarySectionTests {

    @Test func literalEscapesBecomeRealWhitespace() {
        #expect("a\\nb".unescapingLiteralWhitespace() == "a\nb")
        #expect("a\\r\\nb".unescapingLiteralWhitespace() == "a\nb")
        #expect("a\\rb".unescapingLiteralWhitespace() == "a\nb")
        #expect("a\\tb".unescapingLiteralWhitespace() == "a\tb")
    }

    @Test func stringsWithoutBackslashesAreReturnedUnchanged() {
        let text = "line one\nline two"
        #expect(text.unescapingLiteralWhitespace() == text)
    }

    @Test func normalizationAppliesToEveryTextField() {
        let section = SummarySection(
            title: "Decisions\\n",
            body: "First\\nSecond",
            items: ["a\\tb", "plain"],
            photoTimestamps: [12]
        )
        let normalized = section.normalizedWhitespace()
        #expect(normalized.title == "Decisions\n")
        #expect(normalized.body == "First\nSecond")
        #expect(normalized.items == ["a\tb", "plain"])
        #expect(normalized.photoTimestamps == [12])
    }

    @Test func defaultsAreEmpty() {
        let section = SummarySection(title: "Only a title")
        #expect(section.body.isEmpty)
        #expect(section.items.isEmpty)
        #expect(section.photoTimestamps.isEmpty)
    }

    @Test func legacyJSONWithoutPhotoTimestampsDecodes() throws {
        let json = #"{"title":"T","body":"B","items":["x"]}"#
        let section = try JSONDecoder().decode(SummarySection.self, from: Data(json.utf8))
        #expect(section == SummarySection(title: "T", body: "B", items: ["x"]))
    }

    @Test func roundTripKeepsPhotoTimestamps() throws {
        let section = SummarySection(title: "T", body: "B", items: [], photoTimestamps: [1.5, 30])
        let data = try JSONEncoder().encode(section)
        #expect(try JSONDecoder().decode(SummarySection.self, from: data) == section)
    }

    @Test func missingRequiredFieldsFailToDecode() {
        let json = #"{"title":"T"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SummarySection.self, from: Data(json.utf8))
        }
    }
}

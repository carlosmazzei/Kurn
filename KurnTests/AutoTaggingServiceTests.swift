//
//  AutoTaggingServiceTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct AutoTaggingServiceTests {

    @Test func parsesTagJSONInsideGeminiMarkdownFence() throws {
        let tagID = UUID()
        let raw = """
        ```json
        {"existing":["\(tagID.uuidString)"],"new":["Architecture"]}
        ```
        """

        let result = try AutoTaggingService.parseSuggestion(
            text: raw,
            availableTags: [.init(id: tagID, name: "Existing")]
        )

        #expect(result.tagIDs == [tagID])
        #expect(result.newTagNames == ["Architecture"])
    }

    @Test func parsesTagJSONSurroundedByProseAndAllowsMissingKeys() throws {
        let result = try AutoTaggingService.parseSuggestion(
            text: #"Here is the result: {"new":[" Follow-up "]} Done."#,
            availableTags: []
        )

        #expect(result.tagIDs.isEmpty)
        #expect(result.newTagNames == ["Follow-up"])
    }

    @Test func malformedTagResponseThrowsInsteadOfSilentlyReturningEmpty() {
        #expect(throws: AppError.self) {
            try AutoTaggingService.parseSuggestion(
                text: "not JSON",
                availableTags: []
            )
        }
    }
}

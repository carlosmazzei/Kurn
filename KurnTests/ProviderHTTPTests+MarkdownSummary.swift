//
//  ProviderHTTPTests+MarkdownSummary.swift
//  KurnTests
//
//  The Markdown summary contract seen through a real provider: a reply's
//  "## " headings become sections and its photo-reference line becomes
//  timestamps. An extension of `ProviderHTTPTests` rather than its own suite:
//  it scripts the process-global `MockURLProtocol`, and `.serialized` only
//  orders tests within one suite.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {

    @Test func aMarkdownSummaryReplyIsSplitIntoSections() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "content": [["type": "text", "text": "## Decisions\n- [ ] Ship it\n📷 [00:12]\n\n## Risks\nNone"]]
            ])
        ])
        let provider = AnthropicProvider(apiKey: "ak", session: MockURLProtocol.session())

        let result = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        #expect(result.sections.map(\.title) == ["Decisions", "Risks"])
        #expect(result.sections.first?.body == "- [ ] Ship it")
        #expect(result.sections.first?.photoTimestamps == [12])
    }
}

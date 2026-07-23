//
//  WikiSynthesisTests.swift
//  KurnTests
//
//  Pure pieces of the cross-meeting synthesis path: whole-article packing (never
//  splitting an article), article rendering with meeting attribution, and the
//  synthesis prompt's counting/attribution instructions.
//

import Foundation
import Testing
@testable import Kurn

struct WikiSynthesisTests {

    private func snapshot(_ title: String, body: String, date: Date = .distantPast) -> WikiArticleSnapshot {
        WikiArticleSnapshot(meetingID: UUID(), title: title, date: date, bodyMarkdown: body)
    }

    // MARK: - Packing

    @Test func packArticlesFitsInSingleBlockWhenUnderBudget() {
        let rendered = ["aaaa", "bbbb", "cccc"]
        let blocks = MeetingChatService.packArticles(rendered, maxChars: 10_000)
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("aaaa"))
        #expect(blocks[0].contains("cccc"))
    }

    @Test func packArticlesSplitsIntoBlocksWithoutCuttingAnArticle() {
        let rendered = ["aaaa", "bbbb", "cccc"] // 4 chars each, "\n\n" join = +2
        let blocks = MeetingChatService.packArticles(rendered, maxChars: 10)
        // "aaaa"+"\n\n"+"bbbb" = 10 fits; "cccc" starts a new block.
        #expect(blocks.count == 2)
        #expect(blocks[0] == "aaaa\n\nbbbb")
        #expect(blocks[1] == "cccc")
        // Every original article survives whole in exactly one block.
        for article in rendered {
            #expect(blocks.filter { $0.contains(article) }.count == 1)
        }
    }

    @Test func packArticlesKeepsOversizedArticleWhole() {
        let big = String(repeating: "x", count: 50)
        let blocks = MeetingChatService.packArticles([big, "y"], maxChars: 10)
        #expect(blocks.contains(big))
    }

    // MARK: - Rendering

    @Test func renderArticleAddsTitleAndDateHeader() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let text = MeetingChatService.renderArticle(snapshot("Q3 Planning", body: "- budget 100k", date: date))
        #expect(text.hasPrefix("### Q3 Planning — "))
        #expect(text.contains("- budget 100k"))
    }

    @Test func renderArticleWithoutDateOmitsSeparator() {
        let text = MeetingChatService.renderArticle(snapshot("Retro", body: "notes"))
        #expect(text.hasPrefix("### Retro\n"))
        #expect(!text.contains("—"))
    }

    @Test func renderArticleFallsBackForUntitled() {
        let text = MeetingChatService.renderArticle(snapshot("", body: "notes"))
        #expect(text.hasPrefix("### "))
        #expect(!text.hasPrefix("### \n")) // resolved to a localized fallback name
    }

    // MARK: - Prompt

    @Test func synthesisSystemPromptEnablesCountingAndAttribution() {
        let prompt = MeetingChatService.synthesisSystemPrompt
        #expect(prompt.localizedCaseInsensitiveContains("count"))
        #expect(prompt.localizedCaseInsensitiveContains("attribute"))
        #expect(prompt.localizedCaseInsensitiveContains("same language"))
    }
}

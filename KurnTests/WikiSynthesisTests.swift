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

    private func snapshot(
        _ title: String, body: String, date: Date = .distantPast, meetingID: UUID = UUID()
    ) -> WikiArticleSnapshot {
        WikiArticleSnapshot(meetingID: meetingID, title: title, date: date, bodyMarkdown: body)
    }

    private func hit(meetingID: UUID) -> SemanticSearchService.Hit {
        SemanticSearchService.Hit(
            chunkID: UUID(), meetingID: meetingID, recordingID: UUID(),
            text: "t", start: 0, end: 1, speakerLabel: "S1", score: 0.5,
            meetingTitle: "M", meetingDate: .distantPast
        )
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

    // MARK: - Article selection

    @Test func selectArticlesForGlobalAggregateReturnsAll() {
        let a = snapshot("A", body: "x", meetingID: UUID())
        let b = snapshot("B", body: "y", meetingID: UUID())
        let articles = [a.meetingID: a, b.meetingID: b]
        // No passages, but a global aggregate → every article is considered.
        let selected = MeetingChatService.selectArticles(
            question: "How many meetings mention risk?", passages: [], articles: articles
        )
        #expect(selected.count == 2)
    }

    @Test func selectArticlesForNormalQuestionFollowsPassageMeetings() {
        let m1 = UUID(), m2 = UUID(), m3 = UUID()
        let a1 = snapshot("A1", body: "x", meetingID: m1)
        let a2 = snapshot("A2", body: "y", meetingID: m2)
        let a3 = snapshot("A3", body: "z", meetingID: m3)
        let articles = [m1: a1, m2: a2, m3: a3]
        // Passages surface m2 then m1 (not m3) → only those articles, in order.
        let selected = MeetingChatService.selectArticles(
            question: "How did the budget evolve?",
            passages: [hit(meetingID: m2), hit(meetingID: m1)], articles: articles
        )
        #expect(selected.map(\.meetingID) == [m2, m1])
    }

    @Test func selectArticlesWithNoArticlesIsEmpty() {
        #expect(MeetingChatService.selectArticles(
            question: "How many meetings?", passages: [], articles: [:]
        ).isEmpty)
    }

    // MARK: - Prompt

    @Test func combinedSystemPromptEnablesCountingAndAttribution() {
        let prompt = MeetingChatService.combinedSystemPrompt
        #expect(prompt.localizedCaseInsensitiveContains("count"))
        #expect(prompt.localizedCaseInsensitiveContains("attribute"))
        #expect(prompt.localizedCaseInsensitiveContains("same language"))
        // Mentions both grounding sources.
        #expect(prompt.localizedCaseInsensitiveContains("notes"))
        #expect(prompt.localizedCaseInsensitiveContains("excerpts"))
    }

    @Test func combinedUserPromptIncludesBothBlocksWhenPresent() {
        let prompt = MeetingChatService.combinedUserPrompt(
            question: "What changed?", articlesBlock: "### A\n- note",
            passagesBlock: "### A\n[0:05] S1: quote", overviewsBlock: ""
        )
        #expect(prompt.contains("What changed?"))
        #expect(prompt.localizedCaseInsensitiveContains("condensed notes"))
        #expect(prompt.contains("- note"))
        #expect(prompt.localizedCaseInsensitiveContains("verbatim excerpts"))
        #expect(prompt.contains("[0:05] S1: quote"))
    }
}

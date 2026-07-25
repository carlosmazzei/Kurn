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

/// Deterministic embedder: returns the vector registered for a string (already
/// normalized by the caller), so cosine selection is exact and OS-free.
private struct StubEmbedder: TextEmbedding {
    let modelIdentifier = "stub-v1"
    let table: [String: [Float]]
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { table[$0] ?? [] } }
}

struct WikiSynthesisTests {

    private func snapshot(
        _ title: String, body: String, date: Date = .distantPast, meetingID: UUID = UUID()
    ) -> WikiArticleSnapshot {
        WikiArticleSnapshot(meetingID: meetingID, title: title, date: date, bodyMarkdown: body)
    }

    private func hit(
        meetingID: UUID, text: String = "t", date: Date = .distantPast
    ) -> SemanticSearchService.Hit {
        SemanticSearchService.Hit(
            chunkID: UUID(), meetingID: meetingID, recordingID: UUID(),
            text: text, start: 0, end: 1, speakerLabel: "S1", score: 0.5,
            meetingTitle: "M", meetingDate: date
        )
    }

    private func normalize(_ v: [Float]) -> [Float] {
        let n = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    private func candidate(meeting: UUID, vector: [Float]) -> SemanticSearchService.Candidate {
        SemanticSearchService.Candidate(
            chunkID: UUID(), meetingID: meeting, recordingID: UUID(),
            text: "x", start: 0, end: 1, speakerLabel: "S1", vector: vector
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

    // MARK: - Article ordering

    @Test func orderedArticlesSortsChronologicallyAndDropsMissing() {
        let older = UUID(), newer = UUID(), noArticle = UUID()
        let a = snapshot("Old", body: "x", date: Date(timeIntervalSince1970: 100), meetingID: older)
        let b = snapshot("New", body: "y", date: Date(timeIntervalSince1970: 900), meetingID: newer)
        let articles = [older: a, newer: b]
        // Passed newest-first and including a meeting with no article.
        let ordered = MeetingChatService.orderedArticles(
            meetingIDs: [newer, noArticle, older], articles: articles
        )
        #expect(ordered.map(\.title) == ["Old", "New"]) // chronological, missing dropped
    }

    // MARK: - Adaptive meeting selection (relevance floor)

    @Test func selectRelevantMeetingsIncludesOnlyMeetingsAboveFloor() async throws {
        let q = normalize([1, 0, 0])
        let m1 = UUID(), m2 = UUID(), m3 = UUID()
        let service = MeetingChatService(
            searchService: SemanticSearchService(embedder: StubEmbedder(table: ["topic": q]))
        )
        let candidates = [
            candidate(meeting: m1, vector: normalize([1, 0, 0])),     // cosine 1.0 → in
            candidate(meeting: m2, vector: normalize([0, 1, 0])),     // cosine 0.0 → out (floor 0.2)
            candidate(meeting: m3, vector: normalize([0.9, 0.1, 0]))  // cosine ~0.99 → in
        ]
        let ids = try await service.selectRelevantMeetings(question: "topic", candidates: candidates)
        #expect(Set(ids) == [m1, m3])
        #expect(!ids.contains(m2))
    }

    // MARK: - Passage rendering (chronological)

    @Test func renderPassagesOrdersMeetingsByDate() {
        let older = UUID(), newer = UUID()
        // Newest meeting's hit appears first, but rendering must put oldest first.
        let block = MeetingChatService.renderPassages([
            hit(meetingID: newer, text: "newer point", date: Date(timeIntervalSince1970: 900)),
            hit(meetingID: older, text: "older point", date: Date(timeIntervalSince1970: 100))
        ])
        let olderIdx = block.range(of: "older point").map { block.distance(from: block.startIndex, to: $0.lowerBound) }
        let newerIdx = block.range(of: "newer point").map { block.distance(from: block.startIndex, to: $0.lowerBound) }
        #expect(olderIdx != nil && newerIdx != nil)
        #expect((olderIdx ?? 0) < (newerIdx ?? 0))
    }

    // MARK: - Prompt

    @Test func combinedSystemPromptEnablesCountingAttributionAndChronology() {
        let prompt = MeetingChatService.combinedSystemPrompt
        #expect(prompt.localizedCaseInsensitiveContains("count"))
        #expect(prompt.localizedCaseInsensitiveContains("attribute"))
        #expect(prompt.localizedCaseInsensitiveContains("same language"))
        // Mentions both grounding sources.
        #expect(prompt.localizedCaseInsensitiveContains("notes"))
        #expect(prompt.localizedCaseInsensitiveContains("excerpts"))
        // Chronological narration for evolution questions.
        #expect(prompt.localizedCaseInsensitiveContains("chronological"))
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

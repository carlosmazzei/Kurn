//
//  LLMBackedServiceTests.swift
//  KurnTests
//
//  The round trips `AutoTaggingService` and
//  `WikiService` make through a scripted LLM: which path a request takes,
//  what each prompt carries, and how an empty, failed or cancelled reply
//  surfaces. The deterministic helpers have their own suites.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct AutoTaggingRoundTripTests {

    private let budget = AutoTaggingService.TagInput(id: UUID(), name: "Budget")
    private let hiring = AutoTaggingService.TagInput(id: UUID(), name: "Hiring")

    @Test func suggestsKnownTagsAndNewNames() async throws {
        let budgetID = budget.id.uuidString
        let llm = ScriptedLLMProvider(chat: { _, _ in
            #"{"existing": ["\#(budgetID)", "not-a-tag"], "new": [" Roadmap ", ""]}"#
        })
        let suggestion = try await AutoTaggingService(resolveProvider: { _, _ in llm }).suggestTags(
            meetingTitle: "Q3 planning",
            transcript: "We reviewed the budget.",
            availableTags: [budget, hiring],
            provider: .openAI,
            model: "m"
        )
        #expect(suggestion.tagIDs == [budget.id])
        #expect(suggestion.newTagNames == ["Roadmap"])
        let prompt = try #require(llm.chatCalls.first?.messages.first?.content)
        #expect(prompt.contains("Meeting title: Q3 planning"))
        #expect(prompt.contains("\(hiring.id.uuidString): Hiring"))
    }

    @Test func blankTranscriptNeverReachesTheProvider() async throws {
        let llm = ScriptedLLMProvider()
        let suggestion = try await AutoTaggingService(resolveProvider: { _, _ in llm }).suggestTags(
            meetingTitle: "t", transcript: " \n ", availableTags: [budget], provider: .openAI, model: "m"
        )
        #expect(suggestion.tagIDs.isEmpty)
        #expect(suggestion.newTagNames.isEmpty)
        #expect(llm.chatCalls.isEmpty)
    }

    @Test func longTranscriptsAreCutAtAWordBoundary() async throws {
        let llm = ScriptedLLMProvider(chat: { _, _ in #"{"existing": [], "new": []}"# })
        let transcript = String(repeating: "palavra ", count: 1_000)
        _ = try await AutoTaggingService(resolveProvider: { _, _ in llm }).suggestTags(
            meetingTitle: "t", transcript: transcript, availableTags: [], provider: .openAI, model: "m"
        )
        let prompt = try #require(llm.chatCalls.first?.messages.first?.content)
        let excerpt = try #require(prompt.components(separatedBy: "Transcript excerpt:\n").last)
        #expect(excerpt.count <= 3_000)
        #expect(excerpt.hasSuffix("palavra ") || excerpt.hasSuffix("palavra"))
    }
}

struct WikiServiceRoundTripTests {

    @Test func wikiUsesTheNotesTemplateAndRendersMarkdown() async throws {
        let llm = ScriptedLLMProvider(summarize: { _, _ in
            SummaryResult(sections: [SummarySection(title: "Decisions", items: ["Ship on Monday [00:42]"])])
        })
        let wiki = WikiService(summaryService: SummaryService(resolveProvider: { _, _ in llm }))
        let markdown = try await wiki.generate(
            transcriptText: "[00:42] Ana: ship on Monday", meetingTitle: "Sync", provider: .openAI, model: "m"
        )
        #expect(markdown == SummaryService.markdownText(from: [
            SummarySection(title: "Decisions", items: ["Ship on Monday [00:42]"])
        ]))
        #expect(llm.summarizeCalls.first?.systemPrompt == SummaryPrompt.system(for: SummaryService.notesTemplate))
    }
}

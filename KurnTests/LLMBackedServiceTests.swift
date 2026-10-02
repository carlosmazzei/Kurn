//
//  LLMBackedServiceTests.swift
//  KurnTests
//
//  The round trips `DocumentGenerationService`, `AutoTaggingService` and
//  `WikiService` make through a scripted LLM: which path a request takes,
//  what each prompt carries, and how an empty, failed or cancelled reply
//  surfaces. The deterministic helpers have their own suites.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct DocumentGenerationRoundTripTests {

    private struct ProviderDown: Error {}

    private func source(_ title: String, transcript: String) -> DocumentTranscriptSource {
        DocumentTranscriptSource(
            meetingID: UUID(),
            title: title,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            transcript: transcript
        )
    }

    private func longTranscript(_ label: String) -> String {
        (0..<200).map { "[00:\(String(format: "%02d", $0 % 60))] Speaker 1: \(label) point \($0)" }
            .joined(separator: "\n")
    }

    @Test func smallSelectionIsOneRequestAndTakesTheHeadingAsTitle() async throws {
        let llm = ScriptedLLMProvider(chat: { _, _ in "# Decisões da semana\n\n- Lançar na segunda" })
        let service = DocumentGenerationService(resolveProvider: { _, _ in llm })
        let result = try await service.generate(
            sources: [source("Sync", transcript: "[00:01] Ana: lançamos na segunda")],
            prompt: "  Liste as decisões  ",
            provider: .openAI,
            model: "m"
        )
        #expect(result.title == "Decisões da semana")
        #expect(result.markdown.hasPrefix("# Decisões da semana"))
        let call = try #require(llm.chatCalls.first)
        #expect(llm.chatCalls.count == 1)
        #expect(call.options == .document)
        #expect(call.messages.first?.content.contains("Liste as decisões") == true)
        #expect(call.messages.first?.content.contains("lançamos na segunda") == true)
    }

    @Test func largeSelectionIsExtractedPerBlockThenReduced() async throws {
        let llm = ScriptedLLMProvider(provider: .appleOnDevice, chat: { _, index in "# Doc \(index)\n\nnotes \(index)" })
        let service = DocumentGenerationService(resolveProvider: { _, _ in llm })
        let sources = [source("A", transcript: longTranscript("alpha")), source("B", transcript: longTranscript("beta"))]
        let stages = Recorded<String>()
        let result = try await service.generate(
            sources: sources,
            prompt: "Compare the meetings",
            provider: .appleOnDevice,
            model: "on-device",
            onProgress: { stage, total in stages.append("\(stage)/\(total)") }
        )
        let blocks = DocumentGenerationService.renderBlocks(sources, maxChars: SummaryService.mapBlockChars(for: .appleOnDevice))
        #expect(blocks.count > 1)
        let calls = llm.chatCalls
        #expect(calls.count == blocks.count + 1)
        #expect(calls[0].messages.first?.content.contains("Source part 1 of \(blocks.count):") == true)
        #expect(calls.last?.messages.first?.content.contains("## Source part 1") == true)
        #expect(stages.values.last == "\(blocks.count + 1)/\(blocks.count + 1)")
        #expect(result.title == "Doc \(blocks.count)")
    }

    @Test func blankReplyIsAnError() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in "   \n" })
        let service = DocumentGenerationService(resolveProvider: { _, _ in llm })
        do {
            _ = try await service.generate(
                sources: [source("Sync", transcript: "texto")], prompt: "Resuma", provider: .openAI, model: "m"
            )
            Issue.record("expected a failure")
        } catch let error as AppError {
            #expect(error.logCode == AppError.documentGenerationFailed("").logCode)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func providerAndRequestFailuresPropagate() async {
        let unresolved = DocumentGenerationService(resolveProvider: { _, _ in throw AppError.noAPIKey(provider: "OpenAI") })
        await #expect(throws: AppError.self) {
            _ = try await unresolved.generate(
                sources: [source("Sync", transcript: "texto")], prompt: "Resuma", provider: .openAI, model: "m"
            )
        }
        let failing = ScriptedLLMProvider(chat: { _, _ in throw ProviderDown() })
        await #expect(throws: ProviderDown.self) {
            _ = try await DocumentGenerationService(resolveProvider: { _, _ in failing }).generate(
                sources: [source("Sync", transcript: "texto")], prompt: "Resuma", provider: .openAI, model: "m"
            )
        }
    }

    @Test func cancellationIsReportedAsCancellation() async {
        let cancelled = ScriptedLLMProvider(chat: { _, _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            _ = try await DocumentGenerationService(resolveProvider: { _, _ in cancelled }).generate(
                sources: [source("Sync", transcript: "texto")], prompt: "Resuma", provider: .openAI, model: "m"
            )
        }
    }
}

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

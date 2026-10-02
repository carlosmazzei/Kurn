//
//  MeetingChatRoundTripTests.swift
//  KurnTests
//
//  `MeetingChatService`'s entry points against a scripted LLM and a stub
//  embedder: the whole-transcript answer for a meeting that fits, the
//  retrieval fallback for one that doesn't, the library answer that combines
//  excerpts with wiki articles (in one pass and map-reduced), and the
//  validation and provider failures that stop a question before any call.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

/// Every text embeds to the same unit vector, so every candidate carrying it
/// is a perfect cosine match and retrieval is OS- and model-free.
private struct ConstantEmbedder: TextEmbedding {
    let modelIdentifier = "constant-v1"
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [1, 0, 0] } }
}

struct MeetingChatRoundTripTests {

    private let meetingA = UUID()
    private let meetingB = UUID()

    private func candidate(_ meeting: UUID, _ text: String, at start: TimeInterval) -> SemanticSearchService.Candidate {
        SemanticSearchService.Candidate(
            chunkID: UUID(), meetingID: meeting, recordingID: UUID(),
            text: text, start: start, end: start + 5, speakerLabel: "Speaker 1",
            vector: [1, 0, 0], meetingTitle: meeting == meetingA ? "Planning" : "Review"
        )
    }

    private func service(_ llm: ScriptedLLMProvider) -> MeetingChatService {
        MeetingChatService(
            searchService: SemanticSearchService(embedder: ConstantEmbedder()),
            resolveProvider: { _, _ in llm }
        )
    }

    // MARK: - Single meeting

    @Test func aMeetingThatFitsIsAnsweredFromItsWholeTranscript() async throws {
        let llm = ScriptedLLMProvider(chat: { _, _ in "We ship on Monday [00:42]." })
        let events = Recorded<String>()
        let answer = try await service(llm).answerAboutMeeting(
            question: "  When do we ship?  ",
            history: [ChatMessage(role: .user, content: "Hi"), ChatMessage(role: .assistant, content: "Hello")],
            transcriptText: "[00:42] Ana: we ship on Monday",
            candidates: [],
            provider: .openAI,
            model: "m",
            onEvent: { event in
                if case .delta(let text) = event { events.append(text) }
            }
        )
        #expect(answer.text == "We ship on Monday [00:42].")
        #expect(answer.citations.isEmpty)
        #expect(events.values == ["We ship on Monday [00:42]."])
        let call = try #require(llm.chatCalls.first)
        #expect(llm.chatCalls.count == 1)
        #expect(call.systemPrompt == MeetingChatService.fullContextSystemPrompt)
        #expect(call.messages.count == 3)
        #expect(call.messages.last?.content == MeetingChatService.fullContextPrompt(
            question: "When do we ship?", transcript: "[00:42] Ana: we ship on Monday"
        ))
    }

    @Test func aMeetingWithoutATranscriptFallsBackToRetrieval() async throws {
        // Calls in order: query rewrite, rerank, answer.
        let llm = ScriptedLLMProvider(chat: { _, index in
            switch index {
            case 0: return "ship date monday"
            case 1: return "2, 1"
            default: return "Monday."
            }
        })
        let candidates = [
            candidate(meetingA, "we talked about hiring", at: 10),
            candidate(meetingA, "we ship on monday", at: 42)
        ]
        let phases = Recorded<ChatPhase>()
        let answer = try await service(llm).answerAboutMeeting(
            question: "When do we ship?",
            history: [],
            transcriptText: "",
            candidates: candidates,
            provider: .openAI,
            model: "m",
            onEvent: { event in
                if case .phase(let phase) = event { phases.append(phase) }
            }
        )
        #expect(answer.text == "Monday.")
        #expect(!answer.citations.isEmpty)
        #expect(llm.chatCalls.count == 3)
        #expect(llm.chatCalls[0].messages.first?.content == "When do we ship?")
        #expect(phases.values == [.rewritingQuery, .retrieving, .reranking, .answering])
    }

    @Test func anUnparseableRerankKeepsTheFusedOrder() async throws {
        let llm = ScriptedLLMProvider(chat: { _, index in index == 1 ? "none of them" : "ok" })
        let answer = try await service(llm).answerAboutMeeting(
            question: "Anything?", history: [], transcriptText: "",
            candidates: [candidate(meetingA, "first point", at: 1), candidate(meetingA, "second point", at: 2)],
            provider: .openAI, model: "m"
        )
        #expect(answer.citations.count == 2)
    }

    // MARK: - Library

    @Test func theLibraryAnswerCombinesExcerptsAndArticlesInOnePass() async throws {
        let llm = ScriptedLLMProvider(chat: { _, index in index < 2 ? "1" : "Both meetings agreed." })
        let articles = [
            meetingA: WikiArticleSnapshot(meetingID: meetingA, title: "Planning", date: Date(timeIntervalSince1970: 100), bodyMarkdown: "- decided to ship"),
            meetingB: WikiArticleSnapshot(meetingID: meetingB, title: "Review", date: Date(timeIntervalSince1970: 900), bodyMarkdown: "- confirmed the date")
        ]
        let answer = try await service(llm).answerAcrossLibrary(
            question: "What did we decide?",
            history: [],
            candidates: [candidate(meetingA, "ship it", at: 5), candidate(meetingB, "date confirmed", at: 8)],
            summariesByMeeting: [meetingA: "Planning overview"],
            articlesByMeeting: articles,
            provider: .openAI,
            model: "m"
        )
        #expect(answer.text == "Both meetings agreed.")
        let final = try #require(llm.chatCalls.last)
        #expect(final.systemPrompt == MeetingChatService.combinedSystemPrompt)
        #expect(final.messages.last?.content.contains("decided to ship") == true)
        #expect(final.messages.last?.content.contains("confirmed the date") == true)
    }

    @Test func aLibraryWithNothingRelevantStillAnswers() async throws {
        let llm = ScriptedLLMProvider(chat: { _, _ in "Nothing in your meetings covers that." })
        let answer = try await service(llm).answerAcrossLibrary(
            question: "What about Mars?", history: [], candidates: [], provider: .openAI, model: "m"
        )
        #expect(answer.text == "Nothing in your meetings covers that.")
        #expect(answer.citations.isEmpty)
        #expect(llm.chatCalls.last?.systemPrompt == MeetingChatService.systemPrompt(for: .library))
    }

    @Test func articlesTooLargeForOnePassAreCondensedThenReduced() async throws {
        let llm = ScriptedLLMProvider(provider: .appleOnDevice, chat: { call, _ in
            call.systemPrompt == MeetingChatService.combinedSystemPrompt ? "Reduced answer." : "condensed"
        })
        let longBody = String(repeating: "- a decision with its owner and date\n", count: 120)
        let articles = [
            meetingA: WikiArticleSnapshot(meetingID: meetingA, title: "Planning", date: Date(timeIntervalSince1970: 100), bodyMarkdown: longBody),
            meetingB: WikiArticleSnapshot(meetingID: meetingB, title: "Review", date: Date(timeIntervalSince1970: 900), bodyMarkdown: longBody)
        ]
        let answer = try await service(llm).answerAcrossLibrary(
            question: "List every decision",
            history: [],
            candidates: [candidate(meetingA, "decision", at: 5), candidate(meetingB, "decision", at: 8)],
            articlesByMeeting: articles,
            provider: .appleOnDevice,
            model: "on-device"
        )
        #expect(answer.text == "Reduced answer.")
        // Query rewrite and rerank, one condense per article block, then the reduce.
        let reduces = llm.chatCalls.filter { $0.systemPrompt == MeetingChatService.combinedSystemPrompt }
        #expect(reduces.count == 1)
        #expect(llm.chatCalls.count >= 5)
    }

    // MARK: - Failures

    @Test func aBlankQuestionNeverReachesTheProvider() async {
        let llm = ScriptedLLMProvider()
        await #expect(throws: AppError.self) {
            _ = try await service(llm).answerAboutMeeting(
                question: "  ", history: [], transcriptText: "texto", candidates: [], provider: .openAI, model: "m"
            )
        }
        #expect(llm.chatCalls.isEmpty)
    }

    @Test func anUnresolvableProviderStopsTheQuestion() async {
        let chat = MeetingChatService(
            searchService: SemanticSearchService(embedder: ConstantEmbedder()),
            resolveProvider: { _, _ in throw AppError.noAPIKey(provider: "OpenAI") }
        )
        await #expect(throws: AppError.self) {
            _ = try await chat.answerAcrossLibrary(
                question: "Anything?", history: [], candidates: [], provider: .openAI, model: "m"
            )
        }
    }
}

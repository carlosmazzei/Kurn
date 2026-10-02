//
//  MeetingChatViewModelSendTests.swift
//  KurnTests
//
//  `MeetingChatViewModel.send` end to end over a `MeetingChatService` with a
//  stub embedder and a scripted provider: a finished exchange is rendered and
//  saved into one session, the library scope carries citations, and a
//  failure or cancellation drops the partial reply and leaves the question
//  retryable.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatViewModelSendTests {

    private struct ProviderDown: Error {}

    private struct ConstantEmbedder: TextEmbedding {
        let modelIdentifier = "constant-v1"
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [1, 0, 0] } }
    }

    private static func viewModel(_ llm: ScriptedLLMProvider) -> MeetingChatViewModel {
        MeetingChatViewModel(chatService: MeetingChatService(
            searchService: SemanticSearchService(embedder: ConstantEmbedder()),
            resolveProvider: { _, _ in llm }
        ))
    }

    private static func ask(_ viewModel: MeetingChatViewModel, _ question: String, transcript: String? = "[00:42] Ana: we ship on monday") {
        viewModel.send(
            question: question,
            transcriptText: transcript,
            candidates: [],
            provider: .openAI,
            model: "gpt-4o"
        )
    }

    private static func waitUntilDone(_ viewModel: MeetingChatViewModel) async {
        let deadline = Date().addingTimeInterval(180)
        while viewModel.isResponding, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aFinishedExchangeIsRenderedAndSavedIntoOneSession() async throws {
        let llm = ScriptedLLMProvider(chat: { _, index in "Answer \(index) [00:42]." })
        let viewModel = Self.viewModel(llm)
        let context = ModelContext(TestModelContainer.make())
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        viewModel.configure(meeting: meeting, modelContext: context)

        Self.ask(viewModel, "  When do we ship?  ")
        #expect(viewModel.isResponding)
        #expect(viewModel.retryableQuestion == nil)
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.turns.map(\.role) == [.user, .assistant])
        #expect(viewModel.turns.first?.text == "When do we ship?")
        #expect(viewModel.turns.last?.text == "Answer 0 [00:42].")
        #expect(viewModel.turns.last?.elapsedSeconds != nil)
        #expect(viewModel.currentPhase == nil)
        #expect(viewModel.error == nil)
        let firstSessionID = try #require(viewModel.currentSessionID)

        Self.ask(viewModel, "And who owns it?")
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.turns.count == 4)
        #expect(viewModel.currentSessionID == firstSessionID)
        let sessions = viewModel.pastSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.turns.count == 4)
        #expect(sessions.first?.meeting?.id == meeting.id)
        // The follow-up carries the first exchange as history.
        #expect((llm.chatCalls.last?.messages.count ?? 0) >= 3)
    }

    @Test func blankOrOverlappingQuestionsAreIgnored() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in "Monday." })
        let viewModel = Self.viewModel(llm)

        Self.ask(viewModel, "   ")
        #expect(viewModel.turns.isEmpty)
        #expect(!viewModel.isResponding)

        Self.ask(viewModel, "When?")
        Self.ask(viewModel, "Again?")
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.turns.map(\.text) == ["When?", "Monday."])
        #expect(llm.chatCalls.count == 1)
    }

    @Test func aLibraryAnswerCarriesItsCitations() async {
        let llm = ScriptedLLMProvider(chat: { _, index in index < 2 ? "1" : "We ship on Monday." })
        let viewModel = Self.viewModel(llm)
        let candidate = SemanticSearchService.Candidate(
            chunkID: UUID(), meetingID: UUID(), recordingID: UUID(),
            text: "we ship on monday", start: 42, end: 47, speakerLabel: "Speaker 1",
            vector: [1, 0, 0], meetingTitle: "Planning"
        )

        viewModel.send(
            question: "When do we ship?",
            transcriptText: nil,
            candidates: [candidate],
            provider: .openAI,
            model: "gpt-4o"
        )
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.turns.last?.text == "We ship on Monday.")
        #expect(viewModel.turns.last?.citations.first?.text == "we ship on monday")

        // A follow-up re-grounds on the previous answer's excerpts.
        let history = MeetingChatViewModel.buildHistory(from: viewModel.turns)
        #expect(history.last?.content.contains("we ship on monday") == true)
    }

    @Test func anAppErrorDropsThePartialReplyAndLeavesTheQuestionRetryable() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in throw AppError.noAPIKey(provider: "OpenAI") })
        let viewModel = Self.viewModel(llm)

        Self.ask(viewModel, "When do we ship?")
        await Self.waitUntilDone(viewModel)

        guard case .noAPIKey = viewModel.error else {
            Issue.record("expected the provider's AppError")
            return
        }
        #expect(viewModel.turns.map(\.role) == [.user])
        #expect(viewModel.retryableQuestion == "When do we ship?")

        viewModel.dropRetryableQuestion()
        #expect(viewModel.turns.isEmpty)
        viewModel.dropRetryableQuestion()
        #expect(viewModel.turns.isEmpty)
    }

    @Test func aNonAppErrorIsWrappedAsAnAPIError() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in throw ProviderDown() })
        let viewModel = Self.viewModel(llm)

        Self.ask(viewModel, "When do we ship?")
        await Self.waitUntilDone(viewModel)

        guard case .apiError(let statusCode, _) = viewModel.error else {
            Issue.record("expected an apiError wrapper")
            return
        }
        #expect(statusCode == 0)
        #expect(viewModel.retryableQuestion == "When do we ship?")
    }

    @Test func cancellationIsSilentAndKeepsTheQuestion() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in throw CancellationError() })
        let viewModel = Self.viewModel(llm)

        Self.ask(viewModel, "When do we ship?")
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.error == nil)
        #expect(viewModel.turns.map(\.role) == [.user])
        #expect(viewModel.retryableQuestion == "When do we ship?")
    }

    @Test func cancellingAnInFlightReplyClearsTheRunningState() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in "Monday." })
        let viewModel = Self.viewModel(llm)

        Self.ask(viewModel, "When do we ship?")
        viewModel.cancel()

        #expect(!viewModel.isResponding)
        #expect(viewModel.retryableQuestion == "When do we ship?")
    }

    @Test func withoutAConfiguredStoreNothingIsSaved() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in "Monday." })
        let viewModel = Self.viewModel(llm)

        Self.ask(viewModel, "When do we ship?")
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.turns.count == 2)
        #expect(viewModel.currentSessionID == nil)
        #expect(viewModel.pastSessions().isEmpty)
    }
}

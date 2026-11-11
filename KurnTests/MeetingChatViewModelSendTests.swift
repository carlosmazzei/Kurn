//
//  MeetingChatViewModelSendTests.swift
//  KurnTests
//
//  `MeetingChatViewModel.send` end to end over a scripted `AgentModel`: a finished exchange
//  is rendered and saved into one session, a provider without agent support is refused with
//  the cloud-provider notice, and a failure or cancellation drops the partial reply and leaves
//  the question retryable.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatViewModelSendTests {
    private static func viewModel(_ model: (any AgentModel)?) -> MeetingChatViewModel {
        MeetingChatViewModel(agentModelFactory: { _, _ in model })
    }

    private static func configured(_ viewModel: MeetingChatViewModel) -> (ModelContext, Meeting) {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        viewModel.configure(meeting: meeting, modelContext: context)
        return (context, meeting)
    }

    private static func ask(_ viewModel: MeetingChatViewModel, _ question: String) {
        viewModel.send(question: question, provider: .openAI, model: "gpt-4o")
    }

    private static func waitUntilDone(_ viewModel: MeetingChatViewModel) async {
        let deadline = Date().addingTimeInterval(180)
        while viewModel.isResponding, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aFinishedExchangeIsRenderedAndSavedIntoOneSession() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Answer 0 [0:42]."), AgentTurnResponse(text: "Answer 1.")])
        let viewModel = Self.viewModel(model)
        let (_, meeting) = Self.configured(viewModel)

        Self.ask(viewModel, "  When do we ship?  ")
        #expect(viewModel.isResponding)
        #expect(viewModel.retryableQuestion == nil)
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.turns.map(\.role) == [.user, .assistant])
        #expect(viewModel.turns.first?.text == "When do we ship?")
        #expect(viewModel.turns.last?.text == "Answer 0 [0:42].")
        #expect(viewModel.turns.last?.elapsedSeconds != nil)
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
        // The follow-up carries the first exchange as plain history.
        let requests = await model.requests
        #expect(requests.last.map { Array($0.messages.prefix(2)) }
            == [.user("When do we ship?"), .assistant(text: "Answer 0 [0:42].", toolCalls: [])])
    }

    @Test func blankOrOverlappingQuestionsAreIgnored() async {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let viewModel = Self.viewModel(model)
        _ = Self.configured(viewModel)

        Self.ask(viewModel, "   ")
        #expect(viewModel.turns.isEmpty)
        #expect(!viewModel.isResponding)

        Self.ask(viewModel, "When?")
        Self.ask(viewModel, "Again?")
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.turns.map(\.text) == ["When?", "Monday."])
        #expect(await model.requests.count == 1)
    }

    @Test func aProviderWithoutAgentSupportIsRefusedWithTheCloudNotice() async {
        let viewModel = Self.viewModel(nil)
        _ = Self.configured(viewModel)

        Self.ask(viewModel, "When do we ship?")
        await Self.waitUntilDone(viewModel)

        guard case .apiError(_, let message) = viewModel.error else {
            Issue.record("expected the cloud-provider notice")
            return
        }
        #expect(message == NSLocalizedString("chat.artifact.cloud_required", comment: ""))
        #expect(viewModel.turns.map(\.role) == [.user])
        #expect(viewModel.retryableQuestion == "When do we ship?")
    }

    @Test func anAppErrorDropsThePartialReplyAndLeavesTheQuestionRetryable() async {
        let viewModel = Self.viewModel(ChatAgentModel(appError: .noAPIKey(provider: "OpenAI")))
        _ = Self.configured(viewModel)

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
        let viewModel = Self.viewModel(ChatAgentModel(fails: true))
        _ = Self.configured(viewModel)

        Self.ask(viewModel, "When do we ship?")
        await Self.waitUntilDone(viewModel)

        guard case .apiError(let statusCode, _) = viewModel.error else {
            Issue.record("expected an apiError wrapper")
            return
        }
        #expect(statusCode == 0)
        #expect(viewModel.retryableQuestion == "When do we ship?")
    }

    @Test func cancellingAnInFlightReplyClearsTheRunningStateOnceSettled() async {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")], pauseAt: 0)
        let viewModel = Self.viewModel(model)
        _ = Self.configured(viewModel)

        Self.ask(viewModel, "When do we ship?")
        for _ in 0..<2_000 where await model.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        viewModel.cancel()
        // A stop is a request: the conversation stays busy until the producer has terminated.
        #expect(viewModel.isResponding)
        #expect(viewModel.phase == .cancelling)
        Self.ask(viewModel, "Ignored while settling")
        await viewModel.waitUntilSettled()

        let cancelled = await model.wasCancelled
        let requestCount = await model.requests.count
        #expect(cancelled)
        #expect(requestCount == 1)
        #expect(!viewModel.isResponding)
        #expect(viewModel.phase == .idle)
        #expect(viewModel.error == nil)
        #expect(viewModel.retryableQuestion == "When do we ship?")
    }

    @Test func withoutAConfiguredStoreTheQuestionStaysRetryable() async {
        let viewModel = Self.viewModel(ChatAgentModel([AgentTurnResponse(text: "Monday.")]))

        Self.ask(viewModel, "When do we ship?")
        await Self.waitUntilDone(viewModel)

        #expect(viewModel.error != nil)
        #expect(viewModel.currentSessionID == nil)
        #expect(viewModel.pastSessions().isEmpty)
        #expect(viewModel.retryableQuestion == "When do we ship?")
    }
}

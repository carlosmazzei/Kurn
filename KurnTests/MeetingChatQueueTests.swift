//
//  MeetingChatQueueTests.swift
//  KurnTests
//
//  NH08 queued input in the chat: steering and follow-ups enter the running reply and show as
//  their own question and answer, a stop hands queued input back to the composer, and a reopened
//  conversation gives back what a dead process left queued.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Holds its first request until opened, so a test can queue input while the reply runs.
actor GatedChatModel: AgentModel {
    let responses: [AgentTurnResponse]
    private(set) var requests: [AgentTurnRequest] = []
    private(set) var isWaiting = false
    private var opened = false

    init(_ responses: [AgentTurnResponse]) { self.responses = responses }

    func open() { opened = true }

    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        requests.append(request)
        if requests.count == 1 {
            // A cancellable wait: a stop during it ends the request.
            isWaiting = true
            defer { isWaiting = false }
            while !opened { try await Task.sleep(for: .milliseconds(5)) }
        }
        try Task.checkCancellation()
        guard responses.indices.contains(requests.count - 1) else { throw ChatAgentModel.Failure.exhausted }
        let response = responses[requests.count - 1]
        onEvent(.textDelta(response.text))
        return response
    }
}

@MainActor
struct MeetingChatQueueTests {
    private func started(_ model: GatedChatModel) async throws -> (MeetingChatViewModel, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        var polls = 0
        while !(await model.isWaiting), polls < 2_000 {
            polls += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await model.isWaiting)
        return (vm, context)
    }

    private func queueRecord(_ vm: MeetingChatViewModel, _ context: ModelContext) throws -> AgentInputQueue.Snapshot {
        let session = try #require(vm.pastSessions().first)
        return ChatInputQueueRecord.load(from: session, store: SwiftDataAgentSessionStore(context: context))
    }

    @Test func steeringEntersTheReplyAndShowsAsItsOwnQuestionAndAnswer() async throws {
        let model = GatedChatModel([AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources")]),
                                    AgentTurnResponse(text: "Monday, as asked.")])
        let (vm, context) = try await started(model)
        #expect(await vm.queue("Only Monday's meeting", as: .steering))
        // Accepted input is saved before it is acknowledged.
        #expect(try queueRecord(vm, context).steering.map(\.text) == ["Only Monday's meeting"])
        await model.open()
        await vm.waitUntilSettled()

        #expect(vm.turns.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(vm.turns[2].text == "Only Monday's meeting")
        #expect(vm.turns.last?.text == "Monday, as asked.")
        let requests = await model.requests
        #expect(requests.count == 2)
        guard case .content(let steering)? = requests.last?.messages.last else { Issue.record("Missing steering"); return }
        #expect(steering.role == .user && steering.text == "Only Monday's meeting")
        // The conversation is saved with the steering turn, and the queue is empty again.
        #expect(try #require(vm.pastSessions().first).turns.map(\.text).contains("Only Monday's meeting"))
        #expect(try queueRecord(vm, context).isEmpty)
        #expect(vm.queued.isEmpty)
    }

    @Test func aFollowUpRunsAfterTheAnswerAndReplayIsNotDuplicated() async throws {
        let model = GatedChatModel([AgentTurnResponse(text: "Monday."), AgentTurnResponse(text: "At ten."),
                                    AgentTurnResponse(text: "Room B.")])
        let (vm, _) = try await started(model)
        #expect(await vm.queue("At what time?", as: .followUp))
        await model.open()
        await vm.waitUntilSettled()

        #expect(vm.turns.map(\.text) == ["When?", "Monday.", "At what time?", "At ten."])
        // A later question replays the run once: its follow-up is not sent a second time.
        vm.send(question: "Where?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let replayed = try #require(await model.requests.last).messages
        let followUps = replayed.filter {
            if case .content(let value) = $0 { return value.role == .user && value.text == "At what time?" }
            return false
        }
        #expect(followUps.count == 1)
        #expect(vm.turns.last?.text == "Room B.")
    }

    @Test func aStopHandsQueuedInputBackToTheComposer() async throws {
        let model = GatedChatModel([AgentTurnResponse(text: "Monday.")])
        let (vm, context) = try await started(model)
        #expect(await vm.queue("Also Tuesday", as: .followUp))
        #expect(vm.queued.followUp.map(\.text) == ["Also Tuesday"])
        vm.cancel()
        await vm.waitUntilSettled()

        #expect(vm.restoredDraft == "Also Tuesday")
        #expect(try queueRecord(vm, context).isEmpty)
        // With no run, nothing can be queued.
        #expect(await vm.queue("Late", as: .steering) == false)
    }

    @Test func editingAndRemovingQueuedInput() async throws {
        let model = GatedChatModel([AgentTurnResponse(text: "Monday.")])
        let (vm, context) = try await started(model)
        #expect(await vm.queue("First", as: .followUp))
        #expect(await vm.queue("Second", as: .followUp))
        for _ in 0..<200 where vm.queued.followUp.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        let items = vm.queued.followUp
        await vm.editQueued(items[0])
        await vm.removeQueued(items[1].id)
        #expect(vm.restoredDraft == "First")
        #expect(try queueRecord(vm, context).isEmpty)
        await model.open()
        await vm.waitUntilSettled()
        #expect(vm.turns.map(\.role) == [.user, .assistant])
    }

    @Test func aReopenedConversationGivesBackWhatADeadProcessLeftQueued() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        let store = SwiftDataAgentSessionStore(context: context)
        let queue = AgentInputQueue()
        try await queue.enqueue("Left behind", as: .steering)
        try ChatInputQueueRecord.save(await queue.snapshot, in: session, store: store)

        let reopened = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        reopened.configure(meeting: meeting, modelContext: context)
        reopened.load(session: session)
        #expect(reopened.restoredDraft == "Left behind")
        #expect(ChatInputQueueRecord.load(from: session, store: store).isEmpty)
    }
}

//
//  ChatConversationHostTests.swift
//  KurnTests
//
//  NH05 host activation: conversations are retained by the app, not the view showing them,
//  so a reply survives its sheet being dismissed; retention is bounded without ever evicting
//  a running conversation, and closing the host settles every run before forgetting it.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatConversationHostTests {
    private static func ask(_ vm: MeetingChatViewModel, _ question: String = "When do we ship?") {
        vm.send(question: question, provider: .openAI, model: "gpt-4o")
    }

    private static func waitForRequest(_ model: ChatAgentModel) async {
        for _ in 0..<2_000 where await model.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func eachScopeHasOneRetainedConversation() {
        let host = ChatConversationHost()
        let meetingID = UUID()
        let meeting = host.conversation(for: meetingID)
        let library = host.conversation(for: nil)
        #expect(host.conversation(for: meetingID) === meeting)
        #expect(host.conversation(for: nil) === library)
        #expect(library !== meeting)
        #expect(host.retainedScopes == [.meeting(meetingID), .library])
    }

    @Test func aRunKeepsGoingAndIsSavedAfterItsViewLetsGo() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let host = ChatConversationHost(makeConversation: { MeetingChatViewModel(agentModelFactory: { _, _ in model }) })
        do {
            // The view's only reference goes out of scope while the reply is still pending.
            let shown = host.conversation(for: meeting.id)
            shown.configure(meeting: meeting, modelContext: context)
            Self.ask(shown)
            #expect(shown.isResponding)
        }
        let reopened = host.conversation(for: meeting.id)
        await reopened.waitUntilSettled()
        #expect(reopened.turns.map(\.text) == ["When do we ship?", "Monday."])
        let saved = try #require(reopened.pastSessions().first)
        #expect(saved.id == reopened.currentSessionID)
    }

    @Test func evictionKeepsRunningConversationsAndClosingSettlesThem() async {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let paused = ChatAgentModel([AgentTurnResponse(text: "Partial")], pauseAt: 0)
        let host = ChatConversationHost(capacity: 1,
                                        makeConversation: { MeetingChatViewModel(agentModelFactory: { _, _ in paused }) })
        let running = host.conversation(for: meeting.id)
        running.configure(meeting: meeting, modelContext: context)
        Self.ask(running)
        await Self.waitForRequest(paused)

        let older = UUID()
        let newer = UUID()
        _ = host.conversation(for: older)
        _ = host.conversation(for: newer)
        #expect(host.retainedScopes == [.meeting(meeting.id), .meeting(newer)])
        #expect(host.conversation(for: meeting.id) === running)

        // Once the run settles, the next open of any scope brings the host back within capacity.
        running.cancel()
        await running.waitUntilSettled()
        _ = host.conversation(for: newer)
        #expect(host.retainedScopes == [.meeting(newer)])
        #expect(running.retryableQuestion == "When do we ship?")

        let again = host.conversation(for: meeting.id)
        again.configure(meeting: meeting, modelContext: context)
        again.send(question: "Still there?", provider: .openAI, model: "gpt-4o")
        await host.closeAll()
        let cancelled = await paused.wasCancelled
        #expect(cancelled)
        #expect(!again.isResponding)
        #expect(host.retainedScopes.isEmpty)
        #expect(host.conversation(for: meeting.id) !== again)
    }

    @Test func capacityIsAtLeastOne() {
        #expect(ChatConversationHost(capacity: 0).capacity == 1)
    }
}

@MainActor
struct MeetingChatSettlementTests {
    private static func configured(_ model: ChatAgentModel) -> (MeetingChatViewModel, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        return (vm, context)
    }

    @Test func phaseFollowsTheRunUntilItSettles() async throws {
        let create = try chatAgentCall("create_document", arguments: .object([
            "title": .string("Draft"), "markdown": .string("Body")
        ]))
        let model = ChatAgentModel([AgentTurnResponse(text: "", toolCalls: [create]), AgentTurnResponse(text: "Writing")], pauseAt: 1)
        let (vm, _) = Self.configured(model)
        #expect(vm.phase == .idle)
        vm.send(question: "Minutes", provider: .openAI, model: "gpt-4o")
        #expect(vm.phase == .preparing)
        for _ in 0..<2_000 where vm.turns.last?.text != "Writing" { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(vm.phase == .streaming)
        vm.cancel()
        #expect(vm.phase == .cancelling)
        await vm.waitUntilSettled()
        #expect(vm.phase == .idle)
        #expect(vm.artifacts.count == 1)
    }

    @Test func resetFencesARunThatIsStillSettling() async {
        let model = ChatAgentModel([AgentTurnResponse(text: "Late")], pauseAt: 0)
        let (vm, _) = Self.configured(model)
        vm.send(question: "Old question", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where await model.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        vm.reset()
        #expect(vm.turns.isEmpty)
        #expect(vm.isResponding)
        await vm.waitUntilSettled()
        #expect(vm.turns.isEmpty)
        #expect(vm.retryableQuestion == nil)
        #expect(vm.pastSessions().isEmpty)
    }

    @Test func theOpenSessionCannotBeDeletedUnderItsRun() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday."), AgentTurnResponse(text: "Later")], pauseAt: 1)
        let (vm, _) = Self.configured(model)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        vm.send(question: "And then?", provider: .openAI, model: "gpt-4o")
        #expect(!vm.delete(session))
        #expect(vm.pastSessions().count == 1)
        vm.cancel()
        await vm.waitUntilSettled()
        #expect(vm.delete(session))
        #expect(vm.pastSessions().isEmpty)
        #expect(vm.turns.isEmpty)
    }
}

@MainActor
final class FakeBackgroundWindow: BackgroundExecutionWindow {
    private(set) var began = 0
    private(set) var ended = 0
    private var onExpiration: (@MainActor @Sendable () -> Void)?

    func begin(name: String, onExpiration: (@MainActor @Sendable () -> Void)?) {
        began += 1
        self.onExpiration = onExpiration
    }

    func end() { ended += 1 }

    func expire() { onExpiration?() }
}

@MainActor
struct MeetingChatBackgroundTests {
    @Test func aRunHoldsABackgroundWindowUntilItSettles() async {
        let window = FakeBackgroundWindow()
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, makeBackgroundWindow: { window })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        #expect(window.began == 1)
        #expect(window.ended == 0)
        await vm.waitUntilSettled()
        #expect(window.ended == 1)
        #expect(vm.turns.last?.text == "Monday.")
    }

    @Test func anExpiredBackgroundWindowStopsTheRunAsAnInterruption() async {
        let window = FakeBackgroundWindow()
        let model = ChatAgentModel([AgentTurnResponse(text: "Partial")], pauseAt: 0)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, makeBackgroundWindow: { window })
        vm.configure(meeting: meeting, modelContext: context)
        let runID = OperationID()
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o", runID: runID)
        for _ in 0..<2_000 where await model.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        window.expire()
        #expect(vm.phase == .cancelling)
        // The system's own expiration can follow the early wind-down; it must not act twice.
        window.expire()
        #expect(vm.phase == .cancelling)
        await vm.waitUntilSettled()
        let cancelled = await model.wasCancelled
        #expect(cancelled)
        #expect(vm.retryableQuestion == "When?")
        #expect(vm.error == nil)
        #expect(window.ended == 1)
        // A late expiration of a settled run changes nothing.
        window.expire()
        #expect(vm.phase == .idle)
    }
}

struct BackgroundDeadlineTests {
    @Test func windsDownOnlyOnceTheRemainingTimeNoLongerCoversTheLead() {
        #expect(!BackgroundDeadline.shouldWindDown(remaining: .greatestFiniteMagnitude))
        #expect(!BackgroundDeadline.shouldWindDown(remaining: 30))
        #expect(!BackgroundDeadline.shouldWindDown(remaining: BackgroundDeadline.windDownLead + 0.5))
        #expect(BackgroundDeadline.shouldWindDown(remaining: BackgroundDeadline.windDownLead))
        #expect(BackgroundDeadline.shouldWindDown(remaining: 0))
        #expect(BackgroundDeadline.shouldWindDown(remaining: 3, lead: 4))
    }
}

struct ChatRunPhaseTests {
    @Test func ownerStatesIgnoreEvents() {
        #expect(ChatRunPhase.idle.applying(.textDelta("x")) == .idle)
        #expect(ChatRunPhase.cancelling.applying(.toolStarted(callID: "1", name: "search", arguments: .object([:]))) == .cancelling)
        #expect(!ChatRunPhase.idle.isBusy)
        #expect(ChatRunPhase.cancelling.isBusy)
    }

    @Test func eventsMoveARunBetweenStreamingAndTools() {
        let started = ChatRunPhase.preparing.applying(.toolStarted(callID: "1", name: "search", arguments: .object([:])))
        #expect(started == .executingTools)
        #expect(started.applying(.toolFinished(callID: "1", name: "search", summary: "", isError: false)) == .executingTools)
        #expect(started.applying(.turnStarted(index: 1)) == .streaming)
        #expect(ChatRunPhase.preparing.applying(.textDelta("x")) == .streaming)
        #expect(ChatRunPhase.streaming.applying(.usage(AgentUsage(inputTokens: 1, outputTokens: 1))) == .streaming)
        #expect(ChatRunPhase.preparing.applying(.runStarted) == .preparing)
    }
}

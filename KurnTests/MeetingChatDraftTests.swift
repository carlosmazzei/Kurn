//
//  MeetingChatDraftTests.swift
//  KurnTests
//
//  A68: the composer's unsent text is kept by the view model and saved with a saved conversation
//  when the app goes to the background, when another conversation opens and before the host lets
//  the view model go; a reopened conversation puts it back, and a sent question clears it.
//

import AgentHarness
import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatDraftTests {
    private static func answered(_ context: ModelContext, meeting: Meeting) async -> MeetingChatViewModel {
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in ChatAgentModel([AgentTurnResponse(text: "Monday.")]) })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When do we ship?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        return vm
    }

    /// The same conversation opened by a view model that knows nothing of the first: another process.
    private static func reopened(_ session: ChatSession, context: ModelContext, meeting: Meeting) -> MeetingChatViewModel {
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in ChatAgentModel([AgentTurnResponse(text: "Tuesday.")]) })
        vm.configure(meeting: meeting, modelContext: context)
        vm.load(session: session)
        return vm
    }

    @Test func aDraftSavedInTheBackgroundComesBackAndASentQuestionClearsIt() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = await Self.answered(context, meeting: meeting)
        let host = ChatConversationHost(makeConversation: { vm })
        #expect(host.conversation(for: meeting.id) === vm)
        let session = try #require(vm.pastSessions().first)
        vm.draft = "And the launch date"

        // Nothing is written while typing, only when the app goes to the background.
        #expect(Self.reopened(session, context: context, meeting: meeting).draft.isEmpty)
        host.saveDrafts()
        let next = Self.reopened(session, context: context, meeting: meeting)
        #expect(next.draft == "And the launch date")
        #expect(!next.holdsUnsavedDraft)

        next.send(question: next.draft, provider: .openAI, model: "gpt-4o")
        await next.waitUntilSettled()
        #expect(next.draft.isEmpty)
        #expect(Self.reopened(session, context: context, meeting: meeting).draft.isEmpty)
    }

    @Test func openingAnotherConversationSavesTheDraftOfTheOneLeft() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = await Self.answered(context, meeting: meeting)
        let first = try #require(vm.pastSessions().first)
        vm.draft = "Unsent"
        vm.reset()
        #expect(vm.draft.isEmpty)
        // A new, unsaved conversation keeps its draft in memory only; opening a conversation with
        // a draft of its own shows both, the text typed here first: nothing typed is dropped.
        vm.draft = "New chat text"
        #expect(vm.holdsUnsavedDraft)
        vm.load(session: first)
        #expect(vm.draft == "New chat text\n\nUnsent")
        vm.draft = "Unsent"

        // Text typed in a new conversation goes along to one with no draft of its own.
        vm.draft = ""
        vm.saveDraft()
        vm.reset()
        vm.draft = "Carried over"
        vm.load(session: first)
        #expect(vm.draft == "Carried over" && vm.holdsUnsavedDraft)
    }

    @Test func theHostKeepsAConversationWhoseDraftHasNowhereToGo() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let host = ChatConversationHost(capacity: 1, makeConversation: {
            MeetingChatViewModel(agentModelFactory: { _, _ in ChatAgentModel([AgentTurnResponse(text: "Monday.")]) })
        })
        let unsaved = host.conversation(for: nil)
        unsaved.draft = "Typed in the library"
        _ = host.conversation(for: UUID())
        #expect(host.conversation(for: nil) === unsaved)

        // A saved conversation's draft is saved, and then it may go.
        let saved = host.conversation(for: meeting.id)
        saved.configure(meeting: meeting, modelContext: context)
        saved.send(question: "When do we ship?", provider: .openAI, model: "gpt-4o")
        await saved.waitUntilSettled()
        let session = try #require(saved.pastSessions().first)
        saved.draft = "Follow-up"
        unsaved.draft = ""
        _ = host.conversation(for: UUID())
        #expect(!host.retainedScopes.contains(.meeting(meeting.id)))
        #expect(Self.reopened(session, context: context, meeting: meeting).draft == "Follow-up")
    }

    /// A question sent from elsewhere than the composer — a resumed interruption — leaves the
    /// composer's saved draft alone; only sending the draft itself clears it.
    @Test func aResumedQuestionLeavesTheDraftAlone() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in
            ChatAgentModel([AgentTurnResponse(text: "Monday."), AgentTurnResponse(text: "Again.")])
        })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When do we ship?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        vm.draft = "And the budget?"
        vm.saveDraft()

        vm.send(question: "When do we ship?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        #expect(vm.draft == "And the budget?")
        #expect(Self.reopened(session, context: context, meeting: meeting).draft == "And the budget?")
    }
}

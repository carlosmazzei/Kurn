//
//  MeetingChatViewModelSessionTests.swift
//  KurnTests
//
//  Exercises `MeetingChatViewModel`'s saved-conversation surface — history
//  scoping, loading, and deletion — against a real in-memory `ModelContext`,
//  independent of `send()`'s LLM round trip (which needs a resolvable
//  provider and isn't exercised here). Sessions are inserted directly, the
//  same shape `ChatSessionTests` uses, standing in for what `persist()` would
//  have created on a real successful exchange.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatViewModelSessionTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func pastSessionsIsEmptyBeforeConfiguring() {
        let vm = MeetingChatViewModel()
        #expect(vm.pastSessions().isEmpty)
    }

    @Test func pastSessionsScopesToTheConfiguredMeetingOnly() throws {
        let context = makeContext()
        let meetingA = Meeting(title: "A")
        let meetingB = Meeting(title: "B")
        context.insert(meetingA)
        context.insert(meetingB)
        context.insert(ChatSession(meeting: meetingA, title: "About A"))
        context.insert(ChatSession(meeting: meetingB, title: "About B"))
        context.insert(ChatSession(meeting: nil, title: "Library-wide"))
        try context.save()

        let vm = MeetingChatViewModel()
        vm.configure(meeting: meetingA, modelContext: context)

        let sessions = vm.pastSessions()
        #expect(sessions.map(\.title) == ["About A"])
    }

    @Test func pastSessionsForTheLibraryWideScopeExcludesPerMeetingOnes() throws {
        let context = makeContext()
        let meeting = Meeting(title: "A")
        context.insert(meeting)
        context.insert(ChatSession(meeting: meeting, title: "About A"))
        context.insert(ChatSession(meeting: nil, title: "Library-wide"))
        try context.save()

        let vm = MeetingChatViewModel()
        vm.configure(meeting: nil, modelContext: context)

        #expect(vm.pastSessions().map(\.title) == ["Library-wide"])
    }

    @Test func pastSessionsOrdersMostRecentlyUpdatedFirst() throws {
        let context = makeContext()
        let older = ChatSession(meeting: nil, title: "Older", createdAt: Date(timeIntervalSince1970: 1000))
        let newer = ChatSession(meeting: nil, title: "Newer", createdAt: Date(timeIntervalSince1970: 2000))
        context.insert(older)
        context.insert(newer)
        try context.save()

        let vm = MeetingChatViewModel()
        vm.configure(meeting: nil, modelContext: context)

        #expect(vm.pastSessions().map(\.title) == ["Newer", "Older"])
    }

    @Test func loadingASessionRestoresItsTurnsAndMarksItCurrent() throws {
        let context = makeContext()
        let session = ChatSession(meeting: nil, title: "Q1 recap")
        session.turns = [
            PersistedChatTurn(id: UUID(), role: .user, text: "What shipped?", citations: [], usage: nil, costUSD: nil, elapsedSeconds: nil),
            PersistedChatTurn(id: UUID(), role: .assistant, text: "The v2 release.", citations: [], usage: nil, costUSD: nil, elapsedSeconds: nil)
        ]
        context.insert(session)
        try context.save()

        let vm = MeetingChatViewModel()
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: session)

        #expect(vm.turns.map(\.text) == ["What shipped?", "The v2 release."])
        #expect(vm.currentSessionID == session.id)
    }

    @Test func deletingTheOpenSessionResetsTheConversation() throws {
        let context = makeContext()
        let session = ChatSession(meeting: nil, title: "Q1 recap")
        session.turns = [
            PersistedChatTurn(id: UUID(), role: .user, text: "Hi", citations: [], usage: nil, costUSD: nil, elapsedSeconds: nil)
        ]
        context.insert(session)
        try context.save()

        let vm = MeetingChatViewModel()
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: session)
        #expect(vm.currentSessionID == session.id)

        vm.delete(session)

        #expect(vm.currentSessionID == nil)
        #expect(vm.turns.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ChatSession>()) == 0)
    }

    @Test func deletingAnotherSessionLeavesTheOpenOneUntouched() throws {
        let context = makeContext()
        let open = ChatSession(meeting: nil, title: "Open")
        let other = ChatSession(meeting: nil, title: "Other")
        context.insert(open)
        context.insert(other)
        try context.save()

        let vm = MeetingChatViewModel()
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: open)

        vm.delete(other)

        #expect(vm.currentSessionID == open.id)
        #expect(try context.fetchCount(FetchDescriptor<ChatSession>()) == 1)
    }

    @Test func resetClearsTurnsAndTheOpenSession() throws {
        let context = makeContext()
        let session = ChatSession(meeting: nil, title: "Q1 recap")
        session.turns = [
            PersistedChatTurn(id: UUID(), role: .user, text: "Hi", citations: [], usage: nil, costUSD: nil, elapsedSeconds: nil)
        ]
        context.insert(session)
        try context.save()

        let vm = MeetingChatViewModel()
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: session)

        vm.reset()

        #expect(vm.currentSessionID == nil)
        #expect(vm.turns.isEmpty)
        // The saved session itself is untouched — reset only starts a new,
        // separate conversation.
        #expect(try context.fetchCount(FetchDescriptor<ChatSession>()) == 1)
    }
}

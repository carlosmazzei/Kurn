//
//  ChatSessionTests.swift
//  KurnTests
//
//  Exercises `ChatSession` against a real in-memory `ModelContainer`: the
//  per-meeting vs. library-wide scope, cascade delete with its meeting, the
//  JSON `turns` round trip (citations and usage included), and the title
//  derivation helper — the same shape `WikiArticleTests` uses for its model.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatSessionTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func insertingASessionPopulatesTheMeetingInverse() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        context.insert(ChatSession(meeting: meeting, title: "What did we decide?"))
        try context.save()

        #expect(meeting.chatSessions.count == 1)
        #expect(meeting.chatSessions.first?.title == "What did we decide?")
    }

    @Test func libraryWideSessionHasNoMeeting() throws {
        let context = makeContext()
        let session = ChatSession(meeting: nil, title: "Across all meetings")
        context.insert(session)
        try context.save()

        #expect(session.meeting == nil)
    }

    @Test func deletingMeetingCascadesToItsChatSessions() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        context.insert(ChatSession(meeting: meeting, title: "One"))
        context.insert(ChatSession(meeting: meeting, title: "Two"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ChatSession>()) == 2)

        context.delete(meeting)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ChatSession>()) == 0)
    }

    @Test func deletingALibraryWideSessionLeavesMeetingsUntouched() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        let session = ChatSession(meeting: nil, title: "Across all meetings")
        context.insert(session)
        try context.save()

        context.delete(session)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 1)
    }

    @Test func turnsRoundTripThroughJSONStorageWithCitationsAndUsage() throws {
        let context = makeContext()
        let session = ChatSession(meeting: nil, title: "Q1 recap")
        context.insert(session)

        let citation = PersistedCitation(
            meetingID: UUID(), recordingID: UUID(), meetingTitle: "Kickoff",
            start: 12.5, speakerLabel: "Speaker 1", text: "We shipped it."
        )
        let turns = [
            PersistedChatTurn(id: UUID(), role: .user, text: "What shipped?", citations: [], usage: nil, costUSD: nil, elapsedSeconds: nil),
            PersistedChatTurn(
                id: UUID(), role: .assistant, text: "The v2 release.", citations: [citation],
                usage: TokenUsage(promptTokens: 120, completionTokens: 40), costUSD: 0.0021, elapsedSeconds: 3.4
            )
        ]
        session.turns = turns
        try context.save()

        // Fresh fetch, not the same in-memory instance, so this proves the
        // JSON round trip rather than just reading back the setter's input.
        let fetched = try #require(try context.fetch(FetchDescriptor<ChatSession>()).first)
        #expect(fetched.turns.count == 2)
        #expect(fetched.turns[1].text == "The v2 release.")
        #expect(fetched.turns[1].usage?.totalTokens == 160)
        #expect(fetched.turns[1].costUSD == 0.0021)
        #expect(fetched.turns[1].citations.first?.speakerLabel == "Speaker 1")
        #expect(fetched.turns[1].citations.first?.start == 12.5)
    }

    @Test func aNewSessionStartsWithNoTurns() {
        let session = ChatSession(meeting: nil, title: "Empty")
        #expect(session.turns.isEmpty)
    }

    @Test func titleFromQuestionTakesTheFirstLineCappedAtSixtyCharacters() {
        #expect(ChatSession.title(from: "  What did we decide about the launch?  ") == "What did we decide about the launch?")
        #expect(ChatSession.title(from: "First line\nSecond line") == "First line")

        let long = String(repeating: "a", count: 100)
        #expect(ChatSession.title(from: long) == String(repeating: "a", count: 60))
    }
}

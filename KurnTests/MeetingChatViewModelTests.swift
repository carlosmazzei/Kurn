//
//  MeetingChatViewModelTests.swift
//  KurnTests
//
//  Covers how prior turns are turned into chat history — specifically that the
//  most recent answer's retrieved excerpts are re-appended so follow-up
//  questions stay grounded in what the previous answer was based on.
//

import Foundation
import Testing
@testable import Kurn

@MainActor
struct MeetingChatViewModelTests {

    private func hit(_ text: String, meetingTitle: String = "Planning") -> SemanticSearchService.Hit {
        SemanticSearchService.Hit(
            chunkID: UUID(), meetingID: UUID(), recordingID: UUID(),
            text: text, start: 30, end: 31, speakerLabel: "Ana", score: 0.8,
            meetingTitle: meetingTitle, meetingDate: .distantPast
        )
    }

    @Test func buildHistoryReAppendsLastAnswerContext() {
        let prior: [MeetingChatViewModel.Turn] = [
            .init(role: .user, text: "What did we decide?"),
            .init(role: .assistant, text: "We shipped v2.", citations: [hit("We shipped v2 in Q3.")])
        ]
        let history = MeetingChatViewModel.buildHistory(from: prior)
        // Plain turns, plus a trailing context reminder referencing the excerpt.
        #expect(history.count == 3)
        #expect(history.last?.role == .user)
        #expect(history.last?.content.contains("We shipped v2 in Q3.") == true)
        #expect(history.last?.content.localizedCaseInsensitiveContains("previous answer") == true)
    }

    @Test func buildHistoryWithoutCitationsAddsNoContext() {
        let prior: [MeetingChatViewModel.Turn] = [
            .init(role: .user, text: "Hi"),
            .init(role: .assistant, text: "Hello, ask me anything.")
        ]
        let history = MeetingChatViewModel.buildHistory(from: prior)
        #expect(history.count == 2)
        #expect(history.map(\.content) == ["Hi", "Hello, ask me anything."])
    }
}

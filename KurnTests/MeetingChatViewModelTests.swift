//
//  MeetingChatViewModelTests.swift
//  KurnTests
//
//  Covers how prior turns are turned into chat history: plain user/assistant text,
//  never old tool payloads or retrieval excerpts.
//

import Foundation
import Testing
@testable import Kurn

@MainActor
struct MeetingChatViewModelTests {
    @Test func buildHistoryReplaysPlainTurnsOnly() {
        let prior: [MeetingChatViewModel.Turn] = [
            .init(role: .user, text: "Hi"),
            .init(role: .assistant, text: "Hello, ask me anything.")
        ]
        let history = MeetingChatViewModel.buildHistory(from: prior)
        #expect(history.map(\.role) == [.user, .assistant])
        #expect(history.map(\.content) == ["Hi", "Hello, ask me anything."])
    }
}

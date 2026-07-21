//
//  MeetingChatServiceTests.swift
//  KurnTests
//
//  Pure tests for the RAG prompt building: grounding instructions and how
//  retrieved passages are rendered into the user turn with citable timestamps.
//

import Foundation
import Testing
@testable import Kurn

struct MeetingChatServiceTests {

    private func hit(_ text: String, start: TimeInterval, speaker: String) -> SemanticSearchService.Hit {
        SemanticSearchService.Hit(
            chunkID: UUID(), meetingID: UUID(), recordingID: UUID(),
            text: text, start: start, end: start + 1, speakerLabel: speaker, score: 0.8
        )
    }

    @Test func systemPromptEnforcesGrounding() {
        let prompt = MeetingChatService.systemPrompt
        #expect(prompt.contains("ONLY"))
        #expect(prompt.contains("[mm:ss]"))
        #expect(prompt.localizedCaseInsensitiveContains("same language"))
    }

    @Test func userPromptRendersExcerptsWithTimestamps() {
        let prompt = MeetingChatService.userPrompt(
            question: "What did we decide about pricing?",
            hits: [
                hit("We agreed to raise prices in Q3.", start: 72, speaker: "Speaker 1"),
                hit("Marketing will announce it.", start: 130, speaker: "Speaker 2")
            ]
        )
        #expect(prompt.contains("What did we decide about pricing?"))
        #expect(prompt.contains("[1:12] Speaker 1: We agreed to raise prices in Q3."))
        #expect(prompt.contains("[2:10] Speaker 2: Marketing will announce it."))
    }

    @Test func userPromptWithNoHitsTellsModelNothingMatched() {
        let prompt = MeetingChatService.userPrompt(question: "Anything about budget?", hits: [])
        #expect(prompt.contains("Anything about budget?"))
        #expect(prompt.localizedCaseInsensitiveContains("no transcript excerpts"))
    }
}

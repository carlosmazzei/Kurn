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

    // MARK: - Full-context path

    @Test func fullContextPromptIncludesQuestionAndTranscript() {
        let transcript = "[0:00] Speaker 1: Welcome.\n[0:05] Speaker 2: Let's start."
        let prompt = MeetingChatService.fullContextPrompt(question: "Who spoke first?", transcript: transcript)
        #expect(prompt.contains("Who spoke first?"))
        #expect(prompt.contains(transcript))
    }

    @Test func fullContextSystemPromptGroundsOnTranscript() {
        let prompt = MeetingChatService.fullContextSystemPrompt
        #expect(prompt.contains("[mm:ss]"))
        #expect(prompt.localizedCaseInsensitiveContains("transcript"))
        #expect(prompt.localizedCaseInsensitiveContains("same language"))
    }

    // MARK: - Rerank / timestamp parsing

    @Test func parseIndicesConvertsToZeroBasedUniqueInRange() {
        #expect(MeetingChatService.parseIndices("4, 1, 9", max: 10) == [3, 0, 8])
        // Out-of-range and duplicates dropped, order preserved.
        #expect(MeetingChatService.parseIndices("2 2 99 3", max: 5) == [1, 2])
        #expect(MeetingChatService.parseIndices("nothing here", max: 5).isEmpty)
    }

    @Test func citedTimestampsParsesBothFormatsInOrder() {
        let text = "See [1:12] then [0:05] and later [1:02:03]; repeat [1:12]."
        #expect(MeetingChatService.citedTimestamps(in: text) == [72, 5, 3723])
    }
}

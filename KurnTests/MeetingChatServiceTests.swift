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

    private func hit(
        _ text: String,
        start: TimeInterval,
        speaker: String,
        meetingID: UUID = UUID(),
        meetingTitle: String = "",
        meetingDate: Date = .distantPast
    ) -> SemanticSearchService.Hit {
        SemanticSearchService.Hit(
            chunkID: UUID(), meetingID: meetingID, recordingID: UUID(),
            text: text, start: start, end: start + 1, speakerLabel: speaker, score: 0.8,
            meetingTitle: meetingTitle, meetingDate: meetingDate
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
            ],
            scope: .singleMeeting,
            summaries: [:]
        )
        #expect(prompt.contains("What did we decide about pricing?"))
        #expect(prompt.contains("[1:12] Speaker 1: We agreed to raise prices in Q3."))
        #expect(prompt.contains("[2:10] Speaker 2: Marketing will announce it."))
        // Single-meeting scope does not add meeting headers.
        #expect(!prompt.contains("###"))
    }

    @Test func userPromptWithNoHitsTellsModelNothingMatched() {
        let prompt = MeetingChatService.userPrompt(
            question: "Anything about budget?", hits: [], scope: .singleMeeting, summaries: [:]
        )
        #expect(prompt.contains("Anything about budget?"))
        #expect(prompt.localizedCaseInsensitiveContains("no transcript excerpts"))
    }

    // MARK: - Library scope (cross-meeting attribution)

    @Test func libraryUserPromptGroupsAndAttributesByMeeting() {
        let planning = UUID()
        let retro = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let prompt = MeetingChatService.userPrompt(
            question: "How did the budget evolve?",
            hits: [
                hit("We set the budget at 100k.", start: 30, speaker: "Ana",
                    meetingID: planning, meetingTitle: "Q3 Planning", meetingDate: date),
                hit("The budget was cut to 80k.", start: 45, speaker: "Bruno",
                    meetingID: retro, meetingTitle: "Q3 Retro", meetingDate: date)
            ],
            scope: .library,
            summaries: [:]
        )
        #expect(prompt.contains("### Q3 Planning"))
        #expect(prompt.contains("### Q3 Retro"))
        #expect(prompt.contains("[0:30] Ana: We set the budget at 100k."))
        #expect(prompt.contains("[0:45] Bruno: The budget was cut to 80k."))
    }

    @Test func libraryUserPromptIncludesOverviewsForHitMeetings() {
        let planning = UUID()
        let prompt = MeetingChatService.userPrompt(
            question: "What was decided?",
            hits: [hit("We shipped v2.", start: 10, speaker: "Ana",
                       meetingID: planning, meetingTitle: "Launch")],
            scope: .library,
            summaries: [planning: "- Shipped v2 on time\n- Deferred v3 scope"]
        )
        #expect(prompt.localizedCaseInsensitiveContains("Meeting overviews"))
        #expect(prompt.contains("Shipped v2 on time"))
    }

    @Test func libraryUserPromptFallsBackToUntitledMeeting() {
        let prompt = MeetingChatService.userPrompt(
            question: "Any decisions?",
            hits: [hit("Decision made.", start: 5, speaker: "Ana")],
            scope: .library,
            summaries: [:]
        )
        // Empty title resolves to the localized fallback rather than a bare "###".
        #expect(!prompt.contains("### \n"))
        #expect(!prompt.contains("### ["))
    }

    @Test func librarySystemPromptAsksForAttribution() {
        let prompt = MeetingChatService.systemPrompt(for: .library)
        #expect(prompt.localizedCaseInsensitiveContains("attribute"))
        #expect(prompt.contains("[mm:ss]"))
        // The single-meeting variant is unchanged.
        #expect(MeetingChatService.systemPrompt(for: .singleMeeting) == MeetingChatService.systemPrompt)
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

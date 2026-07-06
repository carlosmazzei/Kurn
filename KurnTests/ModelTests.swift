//
//  ModelTests.swift
//  KurnTests
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ModelTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    // MARK: - Meeting

    @Test func totalDurationSumsAllRecordings() {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        for duration: TimeInterval in [60, 120, 30] {
            let recording = Recording(meeting: meeting, fileName: "r.m4a", duration: duration)
            context.insert(recording)
        }
        #expect(meeting.totalDuration == 210)
    }

    @Test func aggregateStatusIsNoneWithoutRecordings() {
        let meeting = Meeting(title: "Empty")
        #expect(meeting.aggregateStatus == .none)
    }

    @Test func aggregateStatusIsDoneWhenAllRecordingsDone() {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        for _ in 0..<2 {
            let recording = Recording(
                meeting: meeting, fileName: "r.m4a", duration: 10,
                transcriptionStatus: .done
            )
            context.insert(recording)
        }
        #expect(meeting.aggregateStatus == .done)
    }

    @Test func aggregateStatusIsInProgressWhenAnyRecordingIsInProgress() {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        context.insert(Recording(meeting: meeting, fileName: "a.m4a", duration: 10, transcriptionStatus: .done))
        context.insert(Recording(meeting: meeting, fileName: "b.m4a", duration: 10, transcriptionStatus: .inProgress))
        #expect(meeting.aggregateStatus == .inProgress)
    }

    @Test func aggregateStatusIsFailedWhenAnyRecordingFailedAndNoneInProgress() {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        context.insert(Recording(meeting: meeting, fileName: "a.m4a", duration: 10, transcriptionStatus: .done))
        context.insert(Recording(meeting: meeting, fileName: "b.m4a", duration: 10, transcriptionStatus: .failed))
        #expect(meeting.aggregateStatus == .failed)
    }

    @Test func hasAnyTranscriptReflectsRecordingTranscripts() {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "a.m4a", duration: 10)
        context.insert(recording)
        #expect(meeting.hasAnyTranscript == false)

        let transcript = Transcript(recording: recording)
        context.insert(transcript)
        recording.transcript = transcript
        #expect(meeting.hasAnyTranscript == true)
    }

    // Re-transcription replaces a recording's transcript. The relationship must
    // be detached before the old transcript is deleted, otherwise establishing
    // the new transcript's inverse traps with "relationship already has a value
    // but it's not the target". This mirrors the replace path in
    // `TranscriptionViewModel.transcribe`.
    @Test func replacingTranscriptDetachesTheOldOne() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "a.m4a", duration: 10)
        context.insert(recording)

        let first = Transcript(recording: recording, language: "en")
        context.insert(first)
        try context.save()

        // Detach before delete, then attach the replacement via the initializer.
        recording.transcript = nil
        context.delete(first)
        let second = Transcript(recording: recording, language: "pt-BR")
        context.insert(second)
        try context.save()

        #expect(recording.transcript?.language == "pt-BR")
        let remaining = try context.fetch(FetchDescriptor<Transcript>())
        #expect(remaining.count == 1)
    }

    @Test func languagePropertyRoundTripsThroughRawValue() {
        let meeting = Meeting(title: "Standup", language: .portuguese)
        #expect(meeting.language == .portuguese)
        meeting.language = .english
        #expect(meeting.languageRaw == MeetingLanguage.english.rawValue)
    }

    @Test func languageFallsBackToAutoDetectForUnknownRawValue() {
        let meeting = Meeting(title: "Standup")
        meeting.languageRaw = "not-a-real-language"
        #expect(meeting.language == .autoDetect)
    }

    // MARK: - Speaker

    @Test func displayNameFallsBackToLabelWhenNameIsEmpty() {
        let speaker = Speaker(label: "Speaker 1", color: "#FFFFFF")
        #expect(speaker.displayName == "Speaker 1")

        speaker.name = "Carlos"
        #expect(speaker.displayName == "Carlos")
    }

    // MARK: - Summary

    @Test func sectionsRoundTripThroughJSONStorage() {
        let summary = Summary(
            sections: [SummarySection(title: "Overview", body: "body")],
            provider: .openAI
        )
        #expect(summary.sections == [SummarySection(title: "Overview", body: "body")])

        summary.sections = [SummarySection(title: "Updated", items: ["d"])]
        #expect(summary.sections == [SummarySection(title: "Updated", items: ["d"])])
    }

    @Test func providerPropertyRoundTripsThroughRawValue() {
        let summary = Summary(provider: .anthropic)
        #expect(summary.provider == .anthropic)
        summary.provider = .openAI
        #expect(summary.providerRaw == AIProvider.openAI.rawValue)
    }

    @Test func modelPropertyRoundTripsThroughOptionalStorage() {
        let summary = Summary(provider: .openAI, model: "gpt-4o")
        #expect(summary.model == "gpt-4o")
        summary.model = nil
        #expect(summary.model == nil)
    }

    @Test func generatingASecondSummaryDoesNotDisturbTheFirst() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)

        let now = Date()
        let first = Summary(meeting: meeting, templateName: "General", provider: .openAI, createdAt: now)
        context.insert(first)
        try context.save()

        let second = Summary(
            meeting: meeting, templateName: "Standup", provider: .openAI,
            createdAt: now.addingTimeInterval(1)
        )
        context.insert(second)
        try context.save()

        #expect(meeting.summaries.count == 2)
        #expect(Set(meeting.summaries.map(\.id)) == Set([first.id, second.id]))
        #expect(meeting.latestSummary?.id == second.id)
    }

    @Test func summariesAreCascadeDeletedWithMeeting() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        context.insert(Summary(meeting: meeting, provider: .openAI))
        context.insert(Summary(meeting: meeting, provider: .openAI))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Summary>()).count == 2)

        context.delete(meeting)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Summary>()).isEmpty)
    }

    @Test func summaryMigrationMovesLegacySummaryIntoSummariesArray() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        // Simulate a pre-upgrade row: only the legacy one-to-one slot is set.
        let legacy = Summary(provider: .openAI)
        legacy.meeting = meeting
        meeting.summary = legacy
        context.insert(legacy)
        try context.save()

        SummaryMigration.migrateLegacySummaries(modelContainer: container)

        #expect(meeting.summary == nil)
        #expect(meeting.summaries.map(\.id) == [legacy.id])
    }

    // MARK: - Transcript

    @Test func segmentsRoundTripThroughJSONStorage() {
        let segment = TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "hello")
        let transcript = Transcript(segments: [segment])
        #expect(transcript.segments == [segment])
    }

    @Test func plainTextJoinsSpeakerAndTextPerSegment() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "hi"),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 2, endTime: 4, text: "hello")
        ]
        let transcript = Transcript(segments: segments)
        #expect(transcript.plainText == "Speaker 1: hi\nSpeaker 2: hello")
    }

    // MARK: - Recording

    @Test func transcriptionStatusAndModeRoundTripThroughRawValue() {
        let recording = Recording(fileName: "a.m4a", duration: 1)
        #expect(recording.transcriptionStatus == .none)
        #expect(recording.transcriptionMode == .onDevice)

        recording.transcriptionStatus = .done
        recording.transcriptionMode = .whisperAPI
        #expect(recording.transcriptionStatusRaw == TranscriptionStatus.done.rawValue)
        #expect(recording.transcriptionModeRaw == TranscriptionMode.whisperAPI.rawValue)
    }
}

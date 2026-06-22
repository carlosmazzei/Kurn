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

//
//  AITitleCoordinatorTests.swift
//  KurnTests
//
//  Exercises the deterministic, network-free guards in `AITitleCoordinator
//  .generateTitle` — the same style `WikiArticleTests` uses for
//  `WikiCoordinator`, since an actual generation needs a real provider.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct AITitleCoordinatorTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    @Test func startsWithNoInFlightGenerationAndNoError() {
        let coordinator = AITitleCoordinator()
        #expect(coordinator.generatingMeetingIDs.isEmpty)
        #expect(coordinator.lastError == nil)
    }

    @Test func skipsAMeetingWithNoTranscript() async {
        let coordinator = AITitleCoordinator()
        let meeting = Meeting(title: "Empty")
        let title = await coordinator.generateTitle(for: meeting, settings: AppSettings())
        #expect(title == nil)
        #expect(coordinator.generatingMeetingIDs.isEmpty)
    }

    @Test func skipsAMeetingThatAlreadyHasATitleUnlessForced() async {
        let context = makeContext()
        let coordinator = AITitleCoordinator()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "a.m4a", duration: 10)
        context.insert(recording)
        let transcript = Transcript(
            recording: recording,
            segments: [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "Hello team")]
        )
        context.insert(transcript)
        recording.transcript = transcript
        meeting.aiTitle = "Already Titled"

        // `force: false` (the default) must not even reach the provider —
        // reusing this guard is what makes the automatic post-transcription
        // pass idempotent instead of re-titling every meeting it revisits.
        let title = await coordinator.generateTitle(for: meeting, settings: AppSettings())
        #expect(title == nil)
        #expect(coordinator.generatingMeetingIDs.isEmpty)
        #expect(coordinator.lastError == nil)
    }
}

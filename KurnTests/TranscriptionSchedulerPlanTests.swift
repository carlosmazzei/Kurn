//
//  TranscriptionSchedulerPlanTests.swift
//  KurnTests
//
//  The decisions `TranscriptionScheduler`'s BGTaskScheduler adapter acts on:
//  what request to submit for the waiting work, whether an opened window may
//  run, and the resume pass that re-arms the scheduler while a backlog
//  remains — all without `BGTaskScheduler`, which rejects a test host.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TranscriptionSchedulerPlanTests {

    private static func backgroundCapableSettings() -> AppSettings {
        let settings = MeetingFixtures.isolatedSettings()
        settings.transcriptionEngine = .appleSpeech
        settings.vadEngine = .energyThreshold
        settings.diarizationEngine = .heuristic
        settings.languageDetectionEngine = .byTranscriber
        return settings
    }

    @discardableResult
    private static func recording(
        in context: ModelContext,
        status: TranscriptionStatus = .pending,
        mode: TranscriptionMode = .onDevice
    ) -> Recording {
        let meeting = Meeting(title: "M")
        context.insert(meeting)
        let recording = Recording(
            meeting: meeting,
            fileName: "\(UUID()).m4a",
            duration: 30,
            transcriptionStatus: status,
            transcriptionMode: mode
        )
        context.insert(recording)
        return recording
    }

    // MARK: - Submission plan

    @Test func onDeviceBacklogIsSubmittedWithoutRequiringTheNetwork() {
        let container = TestModelContainer.make()
        Self.recording(in: container.mainContext)
        Self.recording(in: container.mainContext, status: .inProgress)

        let plan = TranscriptionScheduler.submissionPlan(
            context: container.mainContext, settings: Self.backgroundCapableSettings()
        )

        #expect(plan == TranscriptionScheduler.SubmissionPlan(pendingCount: 2, requiresNetworkConnectivity: false))
    }

    @Test func aWhisperUploadInTheBacklogRequiresTheNetwork() {
        let container = TestModelContainer.make()
        Self.recording(in: container.mainContext)
        Self.recording(in: container.mainContext, mode: .whisperAPI)

        let plan = TranscriptionScheduler.submissionPlan(
            context: container.mainContext, settings: Self.backgroundCapableSettings()
        )

        #expect(plan?.requiresNetworkConnectivity == true)
    }

    @Test func nothingIsSubmittedWithoutWorkOrForACoreMLPipeline() {
        let empty = TestModelContainer.make()
        #expect(TranscriptionScheduler.submissionPlan(
            context: empty.mainContext, settings: Self.backgroundCapableSettings()
        ) == nil)

        let busy = TestModelContainer.make()
        Self.recording(in: busy.mainContext)
        let settings = Self.backgroundCapableSettings()
        settings.diarizationEngine = .fluidAudio
        #expect(TranscriptionScheduler.submissionPlan(context: busy.mainContext, settings: settings) == nil)
    }

    // MARK: - Window start

    @Test func aLockedDeviceDefersWithoutAskingForTheStore() {
        var asked = false
        let start = TranscriptionScheduler.windowStart(protectedDataAvailable: false) {
            asked = true
            return nil
        }
        guard case .deferWhileLocked = start else {
            Issue.record("expected a locked device to defer")
            return
        }
        #expect(!asked)
    }

    @Test func anUnopenedStoreDefersAndAnOpenOneRuns() {
        guard case .deferUntilStoreReady = TranscriptionScheduler.windowStart(
            protectedDataAvailable: true, context: { nil }
        ) else {
            Issue.record("expected a missing store to defer")
            return
        }

        let container = TestModelContainer.make()
        let context = BackgroundTranscriptionContext(
            container: container,
            transcription: TranscriptionCoordinator(modelContext: container.mainContext),
            settings: Self.backgroundCapableSettings()
        )
        guard case .run(let running) = TranscriptionScheduler.windowStart(
            protectedDataAvailable: true, context: { context }
        ) else {
            Issue.record("expected an open store to run")
            return
        }
        #expect(running.container === container)
    }

    // MARK: - Resume pass

    @Test func aPassWithNothingLeftDoesNotReschedule() async {
        let container = TestModelContainer.make()
        let context = BackgroundTranscriptionContext(
            container: container,
            transcription: TranscriptionCoordinator(modelContext: container.mainContext),
            settings: Self.backgroundCapableSettings()
        )
        var rescheduled = 0

        let remaining = await BackgroundTranscriptionRunner().run(context) { _ in rescheduled += 1 }

        #expect(remaining == 0)
        #expect(rescheduled == 0)
    }

    @Test func aRemainingBacklogIsCountedAndRescheduled() async {
        // The coordinator works on a different store than the one the pass
        // counts, so the backlog is left exactly as it was found.
        let counted = TestModelContainer.make()
        Self.recording(in: counted.mainContext)
        Self.recording(in: counted.mainContext, status: .done)
        let worked = TestModelContainer.make()
        let context = BackgroundTranscriptionContext(
            container: counted,
            transcription: TranscriptionCoordinator(modelContext: worked.mainContext),
            settings: Self.backgroundCapableSettings()
        )
        let runner = BackgroundTranscriptionRunner()
        var rescheduled = 0

        runner.pause()
        let remaining = await runner.run(context) { _ in rescheduled += 1 }

        #expect(remaining == 1)
        #expect(rescheduled == 1)
    }
}

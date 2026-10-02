//
//  TranscriptionCoordinatorEnrichmentTests.swift
//  KurnTests
//
//  The two `TranscriptionCoordinator` actions that work on an already-saved
//  transcript: retrying only the correction stage (scripted correctors, no
//  LLM) and generating or regenerating the meeting's AI title (scripted LLM).
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TranscriptionCoordinatorEnrichmentTests {

    private struct ProviderDown: Error {}

    /// A corrector that empties every segment's text — identity-preserving, so
    /// it passes the service's own contract check and reaches the coordinator's
    /// integrity gate.
    private struct BlankingCorrector: TranscriptCorrecting {
        func correct(
            segments: [TranscriptSegment],
            language: MeetingLanguage,
            provider: AIProvider,
            model: String,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async -> TranscriptCorrectionResult {
            TranscriptCorrectionResult(segments: segments.map { segment in
                var blank = segment
                blank.text = "  "
                return blank
            })
        }
    }

    private static var correctionConfig: PipelineConfiguration {
        var config = PipelineConfiguration()
        config.correction = .llm
        config.correctionConsented = true
        return config
    }

    private static func coordinator(
        in context: ModelContext,
        catalog: PipelineEngineCatalog = FakeEngines(regions: []).catalog,
        titleReply: @escaping @Sendable (Int) throws -> String = { _ in "Launch plan" }
    ) -> TranscriptionCoordinator {
        let llm = ScriptedLLMProvider(summarize: { _, index in
            SummaryResult(sections: [SummarySection(title: try titleReply(index), body: "")])
        })
        return TranscriptionCoordinator(
            modelContext: context,
            aiTitleCoordinator: AITitleCoordinator(
                summaryService: SummaryService(resolveProvider: { _, _ in llm }),
                providerCircuitBreaker: MeetingFixtures.freshCircuit(),
                isProviderUsable: { _ in true }
            ),
            transcriptionService: TranscriptionService(engines: catalog)
        )
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(180)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Correction retry

    @Test func retryingCorrectionReplacesTheTextAndRecordsTheStage() async throws {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = Self.coordinator(in: context)
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let recording = try #require(meeting.recordings.first)

        coordinator.retryCorrection(recording, language: .english, config: Self.correctionConfig)
        #expect(coordinator.correctionRetryIDs.contains(recording.id))
        await Self.waitUntil { coordinator.correctionRetryIDs.isEmpty }

        #expect(recording.transcript?.segments.map(\.text) == ["WE SHIP ON MONDAY"])
        let stages = recording.transcript?.pipelineReport?.stages.map(\.stage) ?? []
        #expect(stages.contains(.correction))
        #expect(coordinator.error == nil)
    }

    @Test func aRetryAlreadyRunningOrWithoutSegmentsIsIgnored() async throws {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = Self.coordinator(in: context)
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let recording = try #require(meeting.recordings.first)
        let bare = Recording(meeting: meeting, fileName: "bare.m4a", duration: 1)
        context.insert(bare)

        coordinator.retryCorrection(bare, language: .english, config: Self.correctionConfig)
        #expect(coordinator.correctionRetryIDs.isEmpty)

        coordinator.correctionRetryIDs.insert(recording.id)
        coordinator.retryCorrection(recording, language: .english, config: Self.correctionConfig)
        coordinator.correctionRetryIDs.remove(recording.id)
        await Task.yield()
        #expect(recording.transcript?.segments.map(\.text) == ["we ship on monday"])
    }

    @Test func outputFailingTheIntegrityGateIsRejected() async throws {
        let context = ModelContext(TestModelContainer.make())
        var catalog = FakeEngines(regions: []).catalog
        catalog.corrector = { _ in BlankingCorrector() }
        let coordinator = Self.coordinator(in: context, catalog: catalog)
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let recording = try #require(meeting.recordings.first)

        coordinator.retryCorrection(recording, language: .english, config: Self.correctionConfig)
        await Self.waitUntil { coordinator.correctionRetryIDs.isEmpty }

        guard case .transcriptIntegrityFailed = coordinator.error else {
            Issue.record("expected the integrity gate to reject blank text")
            return
        }
        #expect(recording.transcript?.segments.map(\.text) == ["we ship on monday"])
    }

    @Test func aTranscriptReplacedMidRetryIsLeftAlone() async throws {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = Self.coordinator(in: context)
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let recording = try #require(meeting.recordings.first)

        coordinator.retryCorrection(recording, language: .english, config: Self.correctionConfig)
        recording.transcript?.segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 4, text: "a newer run")
        ]
        await Self.waitUntil { coordinator.correctionRetryIDs.isEmpty }

        #expect(recording.transcript?.segments.map(\.text) == ["a newer run"])
    }

    // MARK: - AI title

    @Test func theAutomaticTitleIsPersistedOnTheMeeting() async {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = Self.coordinator(in: context)
        let meeting = MeetingFixtures.transcribed("Untitled", in: context)

        await coordinator.generateAITitle(for: nil, settings: MeetingFixtures.isolatedSettings())
        await coordinator.generateAITitle(for: meeting, settings: MeetingFixtures.isolatedSettings())

        #expect(meeting.aiTitle == "Launch plan")
        #expect(!coordinator.isGeneratingTitle(for: meeting))
    }

    @Test func regeneratingReplacesAnExistingTitle() async {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = Self.coordinator(in: context, titleReply: { index in "Title \(index)" })
        let meeting = MeetingFixtures.transcribed("Untitled", in: context)
        meeting.aiTitle = "Old title"

        coordinator.regenerateTitle(for: meeting, settings: MeetingFixtures.isolatedSettings())
        await Self.waitUntil { meeting.aiTitle != "Old title" }

        #expect(meeting.aiTitle == "Title 0")
        #expect(coordinator.error == nil)
    }

    @Test func aFailedRegenerationSurfacesOnceThroughError() async {
        let context = ModelContext(TestModelContainer.make())
        let coordinator = Self.coordinator(in: context, titleReply: { _ in throw ProviderDown() })
        let meeting = MeetingFixtures.transcribed("Untitled", in: context)

        coordinator.regenerateTitle(for: meeting, settings: MeetingFixtures.isolatedSettings())
        await Self.waitUntil { coordinator.error != nil }

        guard case .titleGenerationFailed = coordinator.error else {
            Issue.record("expected the regeneration failure to surface")
            return
        }
        #expect(coordinator.aiTitleCoordinator.lastError == nil)
        #expect(meeting.aiTitle == nil)
    }
}

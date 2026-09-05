//
//  TranscriptionViewModelStateMachineTests.swift
//  KurnTests
//
//  `TranscriptionViewModel.transcribe`/`startTranscription` driven end to end
//  over a `TranscriptionService` whose every stage is a scripted fake
//  (`FakePipelineEngines`): the status transitions a recording goes through,
//  which per-recording state the view model exposes while a run is in flight,
//  and how success, engine failure, pause (cancel) and full stop each settle
//  the recording and its checkpoint. No speech service, model or network is
//  involved; the only real I/O is a short PCM fixture placed where the
//  recording's `fileURL` resolves.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite("TranscriptionViewModel state machine")
struct TranscriptionViewModelStateMachineTests {

    private static let regions = [
        SpeechRegion(start: 0.2, end: 1.2),
        SpeechRegion(start: 1.8, end: 2.8)
    ]

    private static func config(
        transcription: TranscriptionEngine = .whisperAPI
    ) -> PipelineConfiguration {
        var config = PipelineConfiguration()
        config.preprocessing = .none
        config.transcription = transcription
        config.cloudTranscriptionConsented = transcription == .whisperAPI
        config.diarization = .heuristic
        return config
    }

    @MainActor
    private final class Harness {
        let container: ModelContainer
        let context: ModelContext
        let engines: FakeEngines
        let viewModel: TranscriptionViewModel
        let meeting: Meeting
        let recording: Recording
        private let fileName: String

        init() throws {
            container = TestModelContainer.make()
            context = container.mainContext
            engines = FakeEngines(regions: TranscriptionViewModelStateMachineTests.regions)
            viewModel = TranscriptionViewModel(
                modelContext: context,
                transcriptionService: TranscriptionService(engines: engines.catalog)
            )
            meeting = Meeting(title: "State machine")
            context.insert(meeting)
            fileName = "vm-\(UUID().uuidString).wav"
            let fixture = try AudioFixtures.wav(segments: [(220, 3.0)])
            let destination = try AudioFileStore.ensureRecordingsDirectory().appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: fixture, to: destination)
            recording = Recording(meeting: meeting, fileName: fileName, duration: 3)
            context.insert(recording)
            try context.save()
        }

        deinit {
            AudioFileStore.delete(fileName: fileName)
        }

        func waitForCheckpoint() async {
            for _ in 0..<2_000 where recording.transcriptionCheckpointData == nil {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @Test func successfulRunPersistsTheTranscriptAndClearsEveryInFlightMarker() async throws {
        let harness = try Harness()
        let recording = harness.recording

        await harness.viewModel.transcribe(recording, language: .english, config: Self.config())

        #expect(recording.transcriptionStatus == .done)
        #expect(recording.transcriptionMode == TranscriptionEngine.whisperAPI.storageMode)
        #expect(recording.transcript?.segments.map(\.text) == ["hello", "world"])
        #expect(recording.transcript?.language == "en")
        #expect(recording.transcript?.pipelineReportData != nil)
        #expect(recording.transcriptionCheckpointData == nil)
        #expect(!harness.viewModel.isTranscribing(recording))
        #expect(!harness.viewModel.isCancelling(recording))
        #expect(harness.viewModel.phase(for: recording) == nil)
        #expect(harness.viewModel.transcriptionError(for: recording) == nil)
        #expect(!TranscriptionViewModel.activeTranscriptionIDs.contains(recording.id))
        #expect(harness.engines.transcriber.requests.count == 1)
    }

    @Test func recordingStillBeingCapturedIsRefusedBeforeAnyEngineRuns() async throws {
        let harness = try Harness()
        let recording = harness.recording
        recording.captureState = .recoveryNeeded

        await harness.viewModel.transcribe(recording, language: .english, config: Self.config())

        #expect(recording.transcriptionStatus == .none)
        #expect(harness.engines.transcriber.requests.isEmpty)
    }

    @Test func engineFailureMarksFailedKeepsTheCheckpointAndAttributesTheError() async throws {
        let harness = try Harness()
        let recording = harness.recording
        harness.engines.transcriber.setFailure(AppError.transcriptionFailed("engine"))

        await harness.viewModel.transcribe(recording, language: .english, config: Self.config())

        #expect(recording.transcriptionStatus == .failed)
        #expect(recording.transcript == nil)
        guard case .transcriptionFailed(let detail) = harness.viewModel.transcriptionError(for: recording) else {
            Issue.record("expected the engine's AppError to be attributed to the recording")
            return
        }
        #expect(detail == "engine")
        #expect(harness.viewModel.error == nil)
        #expect(!harness.viewModel.isTranscribing(recording))

        harness.viewModel.clearTranscriptionError(for: recording)
        #expect(harness.viewModel.transcriptionError(for: recording) == nil)
    }

    @Test func nonAppErrorFromTheEngineIsWrappedAsTranscriptionFailed() async throws {
        let harness = try Harness()
        let recording = harness.recording
        harness.engines.transcriber.setFailure(FakeEngineError.dsp)

        await harness.viewModel.transcribe(recording, language: .english, config: Self.config())

        #expect(recording.transcriptionStatus == .failed)
        guard case .transcriptionFailed = harness.viewModel.transcriptionError(for: recording) else {
            Issue.record("expected a wrapped transcriptionFailed error")
            return
        }
    }

    @Test func pauseKeepsTheCheckpointAndParksTheRecordingAsPending() async throws {
        let harness = try Harness()
        let recording = harness.recording
        harness.engines.transcriber.holdAfterFirstChunk()

        harness.viewModel.startTranscription(recording, language: .english, config: Self.config())
        await harness.waitForCheckpoint()
        #expect(harness.viewModel.isTranscribing(recording))
        #expect(recording.transcriptionStatus == .inProgress)

        harness.viewModel.cancelTranscription(recording)
        #expect(harness.viewModel.isCancelling(recording))
        await harness.viewModel.awaitActiveTranscriptions()

        #expect(recording.transcriptionStatus == .pending)
        #expect(recording.transcriptionCheckpoint?.completedChunks == 1)
        #expect(recording.transcript == nil)
        #expect(!harness.viewModel.isTranscribing(recording))
        #expect(!harness.viewModel.isCancelling(recording))
        #expect(harness.viewModel.transcriptionError(for: recording) == nil)
    }

    @Test func stopDiscardsTheCheckpointAndResetsTheRecording() async throws {
        let harness = try Harness()
        let recording = harness.recording
        harness.engines.transcriber.holdAfterFirstChunk()

        harness.viewModel.startTranscription(recording, language: .english, config: Self.config())
        await harness.waitForCheckpoint()

        harness.viewModel.stopTranscription(recording)
        await harness.viewModel.awaitActiveTranscriptions()

        #expect(recording.transcriptionStatus == .none)
        #expect(recording.transcriptionCheckpointData == nil)
        #expect(!harness.viewModel.isTranscribing(recording))
        #expect(harness.viewModel.transcriptionError(for: recording) == nil)
    }

    @Test func cancelAllParksEveryInFlightRunAsPending() async throws {
        let harness = try Harness()
        let recording = harness.recording
        harness.engines.transcriber.holdAfterFirstChunk()

        harness.viewModel.startTranscription(recording, language: .english, config: Self.config())
        await harness.waitForCheckpoint()

        harness.viewModel.cancelAllTranscriptions()
        await harness.viewModel.awaitActiveTranscriptions()

        #expect(recording.transcriptionStatus == .pending)
        #expect(recording.transcriptionCheckpoint?.completedChunks == 1)
    }

    @Test func aSecondStartForTheSameRecordingIsIgnoredWhileTheFirstIsInFlight() async throws {
        let harness = try Harness()
        let recording = harness.recording
        harness.engines.transcriber.holdAfterFirstChunk()

        harness.viewModel.startTranscription(recording, language: .english, config: Self.config())
        await harness.waitForCheckpoint()
        harness.viewModel.startTranscription(recording, language: .english, config: Self.config())
        await harness.viewModel.transcribe(recording, language: .english, config: Self.config())

        harness.viewModel.stopTranscription(recording)
        await harness.viewModel.awaitActiveTranscriptions()

        #expect(harness.engines.transcriber.requests.count == 1)
    }

    @Test func resumedRunPicksUpFromThePersistedCheckpoint() async throws {
        let harness = try Harness()
        let recording = harness.recording
        harness.engines.transcriber.holdAfterFirstChunk()

        harness.viewModel.startTranscription(recording, language: .english, config: Self.config())
        await harness.waitForCheckpoint()
        harness.viewModel.cancelTranscription(recording)
        await harness.viewModel.awaitActiveTranscriptions()
        #expect(recording.transcriptionStatus == .pending)

        let resumed = FakeEngines(regions: Self.regions)
        let viewModel = TranscriptionViewModel(
            modelContext: harness.context,
            transcriptionService: TranscriptionService(engines: resumed.catalog)
        )
        await viewModel.transcribe(recording, language: .english, config: Self.config())

        #expect(recording.transcriptionStatus == .done)
        #expect(resumed.transcriber.requests.first?.resume?.completedChunks == 1)
        #expect(recording.transcript?.segments.map(\.text) == ["hello", "world"])
    }

    @Test func unconsentedNeuralDiarizationSurfacesAWarningWithoutFailingTheRun() async throws {
        let harness = try Harness()
        let recording = harness.recording
        var config = Self.config()
        config.diarization = .fluidAudio
        config.diarizationConsented = false

        await harness.viewModel.transcribe(recording, language: .english, config: config)

        #expect(recording.transcriptionStatus == .done)
        #expect(harness.viewModel.diarizationWarnings[recording.id] != nil)
        #expect(harness.viewModel.transcriptionError(for: recording) == nil)
    }

    @Test func rerunReplacesTheExistingTranscriptInsteadOfDuplicatingIt() async throws {
        let harness = try Harness()
        let recording = harness.recording

        await harness.viewModel.transcribe(recording, language: .english, config: Self.config())
        harness.engines.transcriber.setSpans([TranscribedSpan(text: "again", start: 0.2, end: 2.8)])
        await harness.viewModel.transcribe(recording, language: .english, config: Self.config())

        #expect(recording.transcript?.segments.map(\.text) == ["again"])
        #expect(try harness.context.fetch(FetchDescriptor<Transcript>()).count == 1)
    }
}

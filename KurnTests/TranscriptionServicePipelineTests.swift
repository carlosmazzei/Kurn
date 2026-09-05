//
//  TranscriptionServicePipelineTests.swift
//  KurnTests
//
//  End-to-end runs of `TranscriptionService.transcribe` with a fake engine per
//  stage (`PipelineEngineCatalog`): phase ordering, stage reports, checkpoint
//  resume/discard, the diarization fallback warning, compaction remapping,
//  degraded-but-continuing stages, cancellation between chunks, and fatal
//  engine failure. No microphone, network, downloaded model, or Apple speech
//  service is involved; the only real I/O is a short PCM fixture the
//  orchestrator reads for its duration and digest.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@Suite("TranscriptionService pipeline with fake engines")
struct TranscriptionServicePipelineTests {

    private static let regions = [
        SpeechRegion(start: 0.2, end: 1.2),
        SpeechRegion(start: 1.8, end: 2.8)
    ]

    private static func fixture() throws -> URL {
        try AudioFixtures.wav(segments: [(220, 3.0)])
    }

    private static func config(
        transcription: TranscriptionEngine = .appleSpeech
    ) -> PipelineConfiguration {
        var config = PipelineConfiguration()
        config.preprocessing = .none
        config.transcription = transcription
        config.cloudTranscriptionConsented = transcription == .whisperAPI
        config.diarization = .heuristic
        return config
    }

    @Test func happyPathReportsEveryStageInOrder() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let phases = PhaseRecorder()

        let output = try await TranscriptionService(engines: harness.catalog).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: Self.config(),
            onPhase: phases.append
        )

        #expect(output.segments.map(\.text) == ["hello", "world"])
        #expect(output.speakerLabels == ["Speaker 1", "Speaker 2"])
        #expect(output.turns.count == 2)
        #expect(output.language == "en")
        #expect(output.report.stages.map(\.stage) == [
            .preprocessing, .languageDetection, .voiceActivityDetection,
            .compaction, .transcription, .diarization, .fusion, .correction
        ])
        #expect(output.report.stages.allSatisfy { $0.outcome != .failed })
        #expect(output.report.stages.first { $0.stage == .compaction }?.outcome == .skipped)
        #expect(output.report.stages.first { $0.stage == .transcription }?.outcome == .succeeded)
        #expect(output.report.stages.first { $0.stage == .diarization }?.outcome == .succeeded)

        let recorded = phases.values
        #expect(Array(recorded.prefix(3)) == [.preprocessing, .detectingSpeech, .transcribing(progress: nil)])
        #expect(recorded.last == .finalizing)
        #expect(recorded.contains(.transcribing(progress: 0.5, chunks: ChunkProgress(completed: 1, total: 2))))
        let firstDiarizing = recorded.firstIndex { if case .diarizing = $0 { return true } else { return false } }
        let lastTranscribing = recorded.lastIndex { if case .transcribing = $0 { return true } else { return false } }
        #expect(firstDiarizing != nil && lastTranscribing != nil)
        #expect((firstDiarizing ?? 0) > (lastTranscribing ?? 0))
        #expect(!recorded.contains(.detectingLanguage))

        #expect(harness.transcriber.requests.count == 1)
        #expect(harness.transcriber.requests.first?.cutPoints == [1.5])
        #expect(harness.diarizer.requests.map(\.regions) == [Self.regions])
        #expect(harness.diarizer.requestedEngines == [.heuristic])
    }

    @Test func unconsentedNeuralDiarizerFallsBackWithWarningAndDegradedReport() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let warnings = WarningRecorder()
        var config = Self.config()
        config.diarization = .fluidAudio
        config.diarizationConsented = false

        let output = try await TranscriptionService(engines: harness.catalog).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: config,
            onDiarizationWarning: warnings.append
        )

        #expect(warnings.values.count == 1)
        #expect(harness.diarizer.requestedEngines == [.heuristic])
        let diarization = output.report.stages.first { $0.stage == .diarization }
        #expect(diarization?.outcome == .degraded)
        #expect(diarization?.reason == .notConsented)
        #expect(diarization?.requestedEngine == DiarizationEngine.fluidAudio.rawValue)
        #expect(diarization?.effectiveEngine == DiarizationEngine.heuristic.rawValue)
    }

    @Test func checkpointFromMatchingRunIsResumedAndMismatchIsDiscarded() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let checkpoints = CheckpointRecorder()
        let config = Self.config(transcription: .whisperAPI)
        let service = TranscriptionService(engines: harness.catalog)

        _ = try await service.transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: config,
            onCheckpoint: checkpoints.append
        )
        let saved = try #require(checkpoints.values.last)
        #expect(saved.completedChunks == 1)
        #expect(saved.totalChunks == 2)
        #expect(saved.engineRaw == TranscriptionEngine.whisperAPI.rawValue)
        #expect(saved.providerID == config.transcriptionProvider.id)
        #expect(saved.compacted == false)
        #expect(saved.fingerprint.sourceDigest != nil)

        _ = try await service.transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: config,
            checkpoint: saved
        )
        let resumed = try #require(harness.transcriber.requests.last)
        #expect(resumed.resume?.completedChunks == 1)
        #expect(resumed.resume?.spans.map(\.text) == ["hello"])

        _ = try await service.transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .portuguese,
            config: config,
            checkpoint: saved
        )
        let discarded = try #require(harness.transcriber.requests.last)
        #expect(discarded.resume == nil)
        #expect(discarded.language == .portuguese)
    }

    @Test func cloudEngineWithoutUploadConsentIsRefusedBeforeTheEngineRuns() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        var config = Self.config(transcription: .whisperAPI)
        config.cloudTranscriptionConsented = false

        await #expect(throws: AppError.self) {
            try await TranscriptionService(engines: harness.catalog).transcribe(
                fileURL: url,
                fileName: "fixture.wav",
                language: .english,
                config: config
            )
        }
        #expect(harness.transcriber.requests.isEmpty)
    }

    @Test func compactedSpansAreRemappedToTheOriginalTimeline() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let compactedURL = AudioFixtures.tempURL(ext: "wav")
        harness.compactor.setResult(.value(CompactionResult(
            url: compactedURL,
            map: [
                TimelineSegment(compactedStart: 0, originalStart: 0.2, duration: 1.0),
                TimelineSegment(compactedStart: 1.1, originalStart: 1.8, duration: 1.0)
            ]
        )))
        harness.transcriber.setSpans([
            TranscribedSpan(text: "hello", start: 0.0, end: 1.0),
            TranscribedSpan(text: "world", start: 1.1, end: 2.1)
        ])

        let output = try await TranscriptionService(engines: harness.catalog).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: Self.config()
        )

        let request = try #require(harness.transcriber.requests.first)
        #expect(request.url == compactedURL)
        #expect(request.cutPoints == [1.1])
        #expect(output.report.stages.first { $0.stage == .compaction }?.outcome == .succeeded)
        #expect(output.segments.map(\.startTime) == [0.2, 1.8])
        #expect(harness.compactor.cleanedUp == [compactedURL])
    }

    @Test func degradedPreprocessingAndCompactionAreReportedAndTheRunContinues() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        harness.preprocessor.setFailure(FakeEngineError.dsp)
        harness.compactor.setResult(.failure(FakeEngineError.compact))
        var config = Self.config()
        config.preprocessing = .standardDSP

        let output = try await TranscriptionService(engines: harness.catalog).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: config
        )

        let preprocessing = output.report.stages.first { $0.stage == .preprocessing }
        #expect(preprocessing?.outcome == .degraded)
        #expect(preprocessing?.reason == .originalAudioUsed)
        let compaction = output.report.stages.first { $0.stage == .compaction }
        #expect(compaction?.outcome == .degraded)
        #expect(compaction?.reason == .engineFailed)
        #expect(output.segments.count == 2)
        #expect(harness.transcriber.requests.first?.url == url)
    }

    @Test func engineFailureAbortsTheRunBeforeDiarization() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        harness.transcriber.setFailure(AppError.transcriptionFailed("engine"))

        await #expect(throws: AppError.self) {
            try await TranscriptionService(engines: harness.catalog).transcribe(
                fileURL: url,
                fileName: "fixture.wav",
                language: .english,
                config: Self.config()
            )
        }
        #expect(harness.diarizer.requests.isEmpty)
    }

    @Test func cancellationBetweenChunksStopsTheRun() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let handle = TaskHandle()

        let task = Task {
            try await TranscriptionService(engines: harness.catalog).transcribe(
                fileURL: url,
                fileName: "fixture.wav",
                language: .english,
                config: Self.config(),
                onCheckpoint: { _ in await handle.cancelOnceSet() }
            )
        }
        handle.set(task)

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(harness.diarizer.requests.isEmpty)
    }

    @Test func emptyTranscriptFromSpeechIsDegradedNotFatal() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        harness.transcriber.setSpans([])

        let output = try await TranscriptionService(engines: harness.catalog).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: Self.config()
        )

        #expect(output.segments.isEmpty)
        let transcription = output.report.stages.first { $0.stage == .transcription }
        #expect(transcription?.outcome == .degraded)
        #expect(transcription?.reason == .noInput)
        #expect(output.language == "en")
    }

    @Test func correctionStageRunsTheSelectedCorrector() async throws {
        let url = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let phases = PhaseRecorder()
        var config = Self.config()
        config.correction = .llm
        config.correctionConsented = true

        let output = try await TranscriptionService(engines: harness.catalog).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: config,
            onPhase: phases.append
        )

        #expect(output.segments.map(\.text) == ["HELLO", "WORLD"])
        #expect(output.report.stages.first { $0.stage == .correction }?.outcome == .succeeded)
        #expect(phases.values.contains(.correcting(progress: nil)))
        #expect(harness.corrector.requestedEngines == [.llm])
    }
}

// MARK: - Recorders

private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [TranscriptionPhase] = []

    func append(_ phase: TranscriptionPhase) {
        lock.withLock { phases.append(phase) }
    }

    var values: [TranscriptionPhase] { lock.withLock { phases } }
}

private final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var warnings: [String] = []

    func append(_ warning: String) {
        lock.withLock { warnings.append(warning) }
    }

    var values: [String] { lock.withLock { warnings } }
}

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints: [TranscriptionCheckpoint] = []

    func append(_ checkpoint: TranscriptionCheckpoint) async throws {
        lock.withLock { checkpoints.append(checkpoint) }
    }

    var values: [TranscriptionCheckpoint] { lock.withLock { checkpoints } }
}

private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<TranscriptionService.Output, Error>?

    func set(_ task: Task<TranscriptionService.Output, Error>) {
        lock.withLock { self.task = task }
    }

    func cancelOnceSet() async {
        while lock.withLock({ task }) == nil {
            await Task.yield()
        }
        lock.withLock { task }?.cancel()
    }
}

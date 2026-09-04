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

/// Engine-internal trouble. Deliberately not an `AppError`: the orchestrator
/// treats those as resource failures and rethrows them instead of degrading.
private enum FakeEngineError: Error {
    case dsp
    case compact
}

// MARK: - Fakes

private struct FakeEngines {
    let preprocessor = FakePreprocessor()
    let transcriber = FakeTranscriber()
    let diarizer = FakeDiarizer()
    let corrector = FakeCorrector()
    let compactor = FakeCompactor()
    let regions: [SpeechRegion]

    var catalog: PipelineEngineCatalog {
        let preprocessor = preprocessor
        let transcriber = transcriber
        let diarizer = diarizer
        let corrector = corrector
        let regions = regions
        return PipelineEngineCatalog(
            preprocessor: { _ in preprocessor },
            languageDetector: { _ in FakeLanguageDetector() },
            vad: { _ in FakeVAD(regions: regions) },
            transcriber: { _ in transcriber },
            diarizer: { engine in
                diarizer.record(engine)
                return diarizer
            },
            corrector: { engine in
                corrector.record(engine)
                switch engine {
                case .none: return NoOpTranscriptCorrector()
                case .llm: return corrector
                }
            },
            diarizationPreprocessor: FakeDiarizationPreprocessor(),
            compactor: compactor
        )
    }
}

/// Lock-guarded mutable state for fakes whose callbacks arrive from arbitrary
/// executors and whose assertions must read synchronously afterwards.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
    func write(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class FakePreprocessor: AudioPreprocessing {
    private let failure = Locked<Error?>(nil)

    func setFailure(_ error: Error) { failure.write { $0 = error } }

    func process(url: URL) async throws -> URL {
        if let error = failure.read({ $0 }) { throw error }
        return url
    }

    func cleanup(_ url: URL) async {}
}

private struct FakeLanguageDetector: LanguageDetecting {
    func detect(url: URL, hint: MeetingLanguage) async -> MeetingLanguage { hint }
}

private struct FakeVAD: VoiceActivityDetecting {
    let regions: [SpeechRegion]
    func detectSpeech(url: URL) async -> [SpeechRegion] { regions }
}

/// Two "chunks": reports progress and a checkpoint after the first, then
/// checks for cancellation before the second — the shape of the real resumable
/// engines' chunk loop, minus the audio.
private final class FakeTranscriber: PipelineTranscribing {
    private struct State {
        var requests: [EngineTranscriptionRequest] = []
        var spans = [
            TranscribedSpan(text: "hello", start: 0.2, end: 1.2),
            TranscribedSpan(text: "world", start: 1.8, end: 2.8)
        ]
        var failure: Error?
    }

    private let state = Locked(State())

    var requests: [EngineTranscriptionRequest] { state.read { $0.requests } }

    func setSpans(_ spans: [TranscribedSpan]) { state.write { $0.spans = spans } }
    func setFailure(_ error: Error) { state.write { $0.failure = error } }

    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript {
        let (spans, failure) = state.read { ($0.spans, $0.failure) }
        state.write { $0.requests.append(request) }
        if let failure { throw failure }
        let total = 2
        let completed = request.resume?.completedChunks ?? 0
        if completed < 1 {
            request.onProgress(0.5, ChunkProgress(completed: 1, total: total))
            try await request.onChunkCompleted?(ChunkedTranscriptionRunner.Progress(
                totalChunks: total,
                completedChunks: 1,
                detectedLanguage: "en",
                planDigest: "plan",
                spans: Array(spans.prefix(1))
            ))
        }
        try Task.checkCancellation()
        request.onProgress(1.0, ChunkProgress(completed: total, total: total))
        return RawTranscript(spans: spans, language: "en")
    }
}

private final class FakeDiarizer: PipelineDiarizing {
    private struct State {
        var requests: [PipelineDiarizationRequest] = []
        var requestedEngines: [DiarizationEngine] = []
    }

    private let state = Locked(State())

    var requests: [PipelineDiarizationRequest] { state.read { $0.requests } }
    var requestedEngines: [DiarizationEngine] { state.read { $0.requestedEngines } }

    func record(_ engine: DiarizationEngine) { state.write { $0.requestedEngines.append(engine) } }

    func diarize(_ request: PipelineDiarizationRequest) async -> DiarizationOutcome {
        state.write { $0.requests.append(request) }
        request.onProgress(0.5)
        request.onProgress(1.0)
        return DiarizationOutcome(turns: [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0.0, end: 1.5),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 1.5, end: 3.0)
        ])
    }
}

private final class FakeCorrector: TranscriptCorrecting {
    private let engines = Locked([CorrectionEngine]())

    var requestedEngines: [CorrectionEngine] { engines.read { $0 } }

    func record(_ engine: CorrectionEngine) { engines.write { $0.append(engine) } }

    func correct(
        segments: [TranscriptSegment],
        language: MeetingLanguage,
        provider: AIProvider,
        model: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> TranscriptCorrectionResult {
        TranscriptCorrectionResult(segments: segments.map { segment in
            var corrected = segment
            corrected.text = segment.text.uppercased()
            return corrected
        })
    }
}

private struct FakeDiarizationPreprocessor: DiarizationPreprocessing {
    func process(url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL { url }
    func cleanup(_ url: URL) async {}
}

private final class FakeCompactor: AudioCompacting {
    enum Result {
        case value(CompactionResult?)
        case failure(Error)
    }

    private let result = Locked(Result.value(nil))
    private let cleaned = Locked([URL]())

    var cleanedUp: [URL] { cleaned.read { $0 } }

    func setResult(_ result: Result) { self.result.write { $0 = result } }

    func compact(url: URL, regions: [SpeechRegion]) async throws -> CompactionResult? {
        switch result.read({ $0 }) {
        case .value(let compaction): return compaction
        case .failure(let error): throw error
        }
    }

    func cleanup(_ url: URL) { cleaned.write { $0.append(url) } }
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

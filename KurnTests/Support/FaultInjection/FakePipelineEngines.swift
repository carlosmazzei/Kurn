//
//  FakePipelineEngines.swift
//  KurnTests
//
//  Scripted stand-ins for every `PipelineEngineCatalog` stage, shared by the
//  `TranscriptionService` pipeline suite and the `TranscriptionViewModel`
//  state-machine suite. None of them touch audio, the network or a model.
//

import Foundation
import KurnCore
@testable import Kurn

/// Engine-internal trouble. Deliberately not an `AppError`: the orchestrator
/// treats those as resource failures and rethrows them instead of degrading.
enum FakeEngineError: Error {
    case dsp
    case compact
}

// MARK: - Fakes

struct FakeEngines {
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
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
    func write(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

final class FakePreprocessor: AudioPreprocessing {
    private let failure = Locked<Error?>(nil)

    func setFailure(_ error: Error) { failure.write { $0 = error } }

    func process(url: URL) async throws -> URL {
        if let error = failure.read({ $0 }) { throw error }
        return url
    }

    func cleanup(_ url: URL) async {}
}

struct FakeLanguageDetector: LanguageDetecting {
    func detect(url: URL, hint: MeetingLanguage) async -> MeetingLanguage { hint }
}

struct FakeVAD: VoiceActivityDetecting {
    let regions: [SpeechRegion]
    func detectSpeech(url: URL) async -> [SpeechRegion] { regions }
}

/// Two "chunks": reports progress and a checkpoint after the first, then
/// checks for cancellation before the second — the shape of the real resumable
/// engines' chunk loop, minus the audio.
final class FakeTranscriber: PipelineTranscribing {
    private struct State {
        var requests: [EngineTranscriptionRequest] = []
        var spans = [
            TranscribedSpan(text: "hello", start: 0.2, end: 1.2),
            TranscribedSpan(text: "world", start: 1.8, end: 2.8)
        ]
        var failure: Error?
        var holdsAfterFirstChunk = false
    }

    private let state = Locked(State())

    var requests: [EngineTranscriptionRequest] { state.read { $0.requests } }

    func setSpans(_ spans: [TranscribedSpan]) { state.write { $0.spans = spans } }
    func setFailure(_ error: Error) { state.write { $0.failure = error } }
    /// Park after the first chunk's checkpoint until the run is cancelled, so
    /// a test can observe the "half done" state and then cancel or stop it.
    func holdAfterFirstChunk() { state.write { $0.holdsAfterFirstChunk = true } }

    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript {
        let (spans, failure, holds) = state.read { ($0.spans, $0.failure, $0.holdsAfterFirstChunk) }
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
            if holds { try await Task.sleep(for: .seconds(3_600)) }
        }
        try Task.checkCancellation()
        request.onProgress(1.0, ChunkProgress(completed: total, total: total))
        return RawTranscript(spans: spans, language: "en")
    }
}

final class FakeDiarizer: PipelineDiarizing {
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

final class FakeCorrector: TranscriptCorrecting {
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

struct FakeDiarizationPreprocessor: DiarizationPreprocessing {
    func process(url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL { url }
    func cleanup(_ url: URL) async {}
}

final class FakeCompactor: AudioCompacting {
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

//
//  PipelineEngineCatalog.swift
//  Kurn
//
//  The set of stage engines `TranscriptionService` drives, resolved per
//  configuration choice. Production uses `.live` — one shared instance of each
//  real engine, reused across concurrent transcriptions so the non-`Sendable`
//  audio resources stay isolated inside their actors — while tests hand the
//  orchestrator fakes per stage and exercise the pipeline end to end without
//  microphones, downloaded models, network, or Apple speech services.
//
//  The two stages whose real engines take more than the `PipelineStages`
//  protocols express — the resumable chunked transcribers and the diarizers
//  with speaker-count/voiceprint/progress contracts — get request-shaped
//  protocols here (`PipelineTranscribing`, `PipelineDiarizing`), with the
//  concrete engines adapted below.
//

import Foundation
import KurnCore

/// One engine pass over the (possibly compacted) transcription input.
struct EngineTranscriptionRequest: Sendable {
    var url: URL
    var language: MeetingLanguage
    /// Cloud provider and model for the `.whisperAPI` engine; ignored elsewhere.
    var provider: AIProvider
    var model: String
    var transferPolicy: LargeTransferPolicy
    /// Weight file for the `.whisperCpp` engine; ignored elsewhere.
    var whisperCppModel: WhisperCppModel
    /// Where a chunk may be cut, on the timeline of `url`.
    var cutPoints: [TimeInterval]
    /// Progress from an earlier interrupted run of the same plan, or `nil`.
    var resume: ChunkedTranscriptionRunner.Progress?
    /// Awaited after each completed chunk; a throw stops the run.
    var onChunkCompleted: (@Sendable (ChunkedTranscriptionRunner.Progress) async throws -> Void)?
    /// `0...1` fraction plus chunk position for engines that chunk.
    var onProgress: @Sendable (Double, ChunkProgress?) -> Void
}

/// A transcription engine as the orchestrator sees it: single-pass engines
/// ignore the chunk plan and resume state, resumable ones honor them.
protocol PipelineTranscribing: Sendable {
    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript
}

/// One diarization pass over its own (possibly preprocessed) input.
struct PipelineDiarizationRequest: Sendable {
    var url: URL
    /// VAD speech regions on the absolute timeline; only the heuristic engine
    /// reads them.
    var regions: [SpeechRegion]
    /// Exact speaker count to pin (`0` = let the engine decide).
    var speakerCount: Int
    /// Non-fatal engine trouble (e.g. a model download failure) the user
    /// should hear about.
    var onWarning: (@Sendable (String) -> Void)?
    var onProgress: @Sendable (Double) -> Void
}

/// A diarization engine as the orchestrator sees it. Never throws: every
/// engine degrades to a whole-clip turn and says so via
/// `DiarizationOutcome.degradation`.
protocol PipelineDiarizing: Sendable {
    func diarize(_ request: PipelineDiarizationRequest) async -> DiarizationOutcome
}

/// Diarization-specific cleanup of the original recording. The returned URL is
/// a temporary the caller owns and must `cleanup`.
protocol DiarizationPreprocessing: Sendable {
    func process(url: URL, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL
    func cleanup(_ url: URL) async
}

/// Silence removal ahead of the transcription engine. `nil` means compaction
/// was not worthwhile and the caller should transcribe the input as is.
protocol AudioCompacting: Sendable {
    func compact(url: URL, regions: [SpeechRegion]) async throws -> CompactionResult?
    func cleanup(_ url: URL)
}

/// Every engine `TranscriptionService` can be configured to run, keyed by the
/// configuration enum that selects it.
struct PipelineEngineCatalog: Sendable {
    var preprocessor: @Sendable (PreprocessingEngine) -> any AudioPreprocessing
    var languageDetector: @Sendable (LanguageDetectionEngine) -> any LanguageDetecting
    var vad: @Sendable (VADEngine) -> any VoiceActivityDetecting
    var transcriber: @Sendable (TranscriptionEngine) -> any PipelineTranscribing
    var diarizer: @Sendable (DiarizationEngine) -> any PipelineDiarizing
    var corrector: @Sendable (CorrectionEngine) -> any TranscriptCorrecting
    var diarizationPreprocessor: any DiarizationPreprocessing
    var compactor: any AudioCompacting

    /// The real engines, instantiated once for the process.
    static let live: PipelineEngineCatalog = {
        let standardPreprocessor = AudioPreprocessor()
        let passthroughPreprocessor = PassthroughPreprocessor()
        let energyVAD = EnergyVAD()
        let fluidAudioVAD = FluidAudioVAD()
        let noOpLanguageDetector = NoOpLanguageDetector()
        let fluidAudioLanguageDetector = FluidAudioLanguageDetector()
        let appleTranscriber = OnDeviceTranscriber()
        let fluidAudioTranscriber = FluidAudioTranscriber()
        let whisperTranscriber = WhisperTranscriber()
        let whisperCppTranscriber = WhisperCppTranscriber()
        let heuristicDiarizer = SpeakerDiarizer()
        let fluidAudioDiarizer = FluidAudioDiarizer()
        let sherpaOnnxDiarizer = SherpaOnnxDiarizer()
        let noOpCorrector = NoOpTranscriptCorrector()
        let llmCorrector = LLMTranscriptCorrector()
        return PipelineEngineCatalog(
            preprocessor: { engine in
                switch engine {
                case .standardDSP: return standardPreprocessor
                case .none: return passthroughPreprocessor
                }
            },
            languageDetector: { engine in
                switch engine {
                case .byTranscriber: return noOpLanguageDetector
                case .fluidAudioLID: return fluidAudioLanguageDetector
                }
            },
            vad: { engine in
                switch engine {
                case .energyThreshold: return energyVAD
                case .fluidAudio: return fluidAudioVAD
                }
            },
            transcriber: { engine in
                switch engine {
                case .appleSpeech: return appleTranscriber
                case .fluidAudioParakeet: return fluidAudioTranscriber
                case .whisperAPI: return whisperTranscriber
                case .whisperCpp: return whisperCppTranscriber
                }
            },
            diarizer: { engine in
                switch engine {
                case .heuristic: return heuristicDiarizer
                case .fluidAudio: return fluidAudioDiarizer
                case .sherpaOnnx: return sherpaOnnxDiarizer
                }
            },
            corrector: { engine in
                switch engine {
                case .none: return noOpCorrector
                case .llm: return llmCorrector
                }
            },
            diarizationPreprocessor: DiarizationPreprocessor(),
            compactor: VADAudioCompactor()
        )
    }()
}

// MARK: - Live engine adapters

extension WhisperTranscriber: PipelineTranscribing {
    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript {
        try await transcribeResumable(
            url: request.url,
            language: request.language,
            provider: request.provider,
            model: request.model,
            transferPolicy: request.transferPolicy,
            cutPoints: request.cutPoints,
            resume: request.resume,
            onChunkCompleted: request.onChunkCompleted,
            onProgress: { progress, completed, total in
                request.onProgress(progress, total > 0 ? ChunkProgress(completed: completed, total: total) : nil)
            }
        )
    }
}

extension WhisperCppTranscriber: PipelineTranscribing {
    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript {
        try await transcribeResumable(
            url: request.url,
            language: request.language,
            model: request.whisperCppModel,
            cutPoints: request.cutPoints,
            resume: request.resume,
            onChunkCompleted: request.onChunkCompleted,
            onProgress: { progress, completed, total in
                request.onProgress(progress, total > 0 ? ChunkProgress(completed: completed, total: total) : nil)
            }
        )
    }
}

extension OnDeviceTranscriber: PipelineTranscribing {
    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript {
        try await transcribe(
            url: request.url,
            language: request.language,
            onProgress: { request.onProgress($0, nil) }
        )
    }
}

extension FluidAudioTranscriber: PipelineTranscribing {
    func transcribe(_ request: EngineTranscriptionRequest) async throws -> RawTranscript {
        try await transcribe(
            url: request.url,
            language: request.language,
            onProgress: { request.onProgress($0, nil) }
        )
    }
}

extension SpeakerDiarizer: PipelineDiarizing {
    /// No voiceprints: three scalars and one greedy clustering pass leave
    /// nothing behind that could identify a voice again later.
    func diarize(_ request: PipelineDiarizationRequest) async -> DiarizationOutcome {
        DiarizationOutcome(turns: await diarize(url: request.url, speechRegions: request.regions))
    }
}

extension FluidAudioDiarizer: PipelineDiarizing {
    func diarize(_ request: PipelineDiarizationRequest) async -> DiarizationOutcome {
        await outcome(
            url: request.url,
            speakerCount: request.speakerCount,
            onDownloadFailure: request.onWarning,
            onProgress: request.onProgress
        )
    }
}

extension SherpaOnnxDiarizer: PipelineDiarizing {
    /// No voiceprints yet: sherpa-onnx's CAM++ embeddings aren't surfaced
    /// through this engine's MVP — see `SherpaOnnxDiarizer`.
    func diarize(_ request: PipelineDiarizationRequest) async -> DiarizationOutcome {
        DiarizationOutcome(turns: await diarize(url: request.url, speakerCount: request.speakerCount))
    }
}

extension DiarizationPreprocessor: DiarizationPreprocessing {}

extension VADAudioCompactor: AudioCompacting {
    func compact(url: URL, regions: [SpeechRegion]) async throws -> CompactionResult? {
        try await compact(url: url, regions: regions, pad: 0.2, gap: 0.1, minSavings: 1.0)
    }
}

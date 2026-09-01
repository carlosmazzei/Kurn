//
//  PipelineStages.swift
//  Kurn
//
//  Protocol seams for each stage of the recognition pipeline so the engine for
//  every stage can be swapped independently. The orchestrator
//  (`TranscriptionService`) resolves an engine per stage from a
//  `PipelineConfiguration` and drives them through these protocols.
//
//  All protocols are `Sendable` value contracts; concrete engines are usually
//  actors wrapping non-`Sendable` audio resources. The intermediate data types
//  (`TranscribedSpan`, `RawTranscript`, `SpeakerTurn`, `Diarizing`) live in
//  `TranscriptionTypes.swift` and are reused as-is.
//

import Foundation
import KurnCore

/// Offline audio cleanup applied before the transcription path. The returned
/// URL may be the input unchanged (passthrough) or a temporary cleaned copy that
/// the caller owns and should `cleanup` when done.
protocol AudioPreprocessing: Sendable {
    func process(url: URL) async throws -> URL
    func cleanup(_ url: URL) async
}

// `SpeechRegion` now lives in the KurnCore package
// (`Sources/KurnCore/Pipeline/SpeechRegion.swift`).

/// Voice-activity detection: locate the spoken regions of a clip. Used both as a
/// standalone stage and internally by the heuristic diarizer.
protocol VoiceActivityDetecting: Sendable {
    func detectSpeech(url: URL) async -> [SpeechRegion]
}

/// Language detection run before transcription. Implementations return a refined
/// `MeetingLanguage`, or the `hint` unchanged when they can't (or needn't) detect
/// — e.g. the no-op detector that defers to the transcription engine.
protocol LanguageDetecting: Sendable {
    func detect(url: URL, hint: MeetingLanguage) async -> MeetingLanguage
}

/// Turn audio into ordered, timed text spans. Apple Speech, FluidAudio Parakeet,
/// and the chunked Whisper path all conform.
///
/// `onProgress` reports a `0...1` fraction for engines that can (the chunked
/// Whisper upload); single-pass engines ignore it. It's a per-call argument
/// rather than actor state so a shared transcriber actor reused across
/// concurrent recordings never leaks one call's handler into another.
protocol Transcribing: Sendable {
    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RawTranscript
}

// `Diarizing` is declared in TranscriptionTypes.swift and is reused unchanged.

/// What a correction pass produced, plus whether it actually ran.
///
/// The segments alone cannot answer that: "no text changed" is the correct
/// result for a clean transcript *and* what an unusable provider or a failed
/// batch leaves behind, so the outcome has to be reported rather than
/// inferred (H5 PR 11).
struct TranscriptCorrectionResult: Sendable {
    var segments: [TranscriptSegment]
    var outcome: PipelineStageOutcome
    var reason: PipelineStageReason?

    init(
        segments: [TranscriptSegment],
        outcome: PipelineStageOutcome = .succeeded,
        reason: PipelineStageReason? = nil
    ) {
        self.segments = segments
        self.outcome = outcome
        self.reason = reason
    }
}

/// Opt-in LLM-based post-processing that corrects transcription errors
/// (spelling, punctuation, homophones, obvious ASR mistakes) on already-fused,
/// speaker-attributed segments. Implementations must never throw and must
/// return exactly `segments.count` segments, in the same order, with every
/// field except `text` unchanged — on any failure (missing key, network
/// error, malformed reply, or a rewrite the guardrail rejects) the original
/// segment's text is kept, and the returned outcome says so. Runs after
/// `TranscriptFusion.segments`, never before: a pre-fusion hook risks
/// perturbing `splitCoarseSpan`'s word-count-based proportional
/// speaker-handover split.
protocol TranscriptCorrecting: Sendable {
    func correct(
        segments: [TranscriptSegment],
        language: MeetingLanguage,
        provider: AIProvider,
        model: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> TranscriptCorrectionResult
}

struct CloudTranscriptionTransfer: Sendable, Equatable {
    var consented = false
    var policy: LargeTransferPolicy = .wifiOnly
}

/// One engine choice per pipeline stage. Built from `AppSettings` and passed to
/// `TranscriptionService.transcribe`. Defaults match the always-available,
/// no-download engines so a fresh install works offline with no model fetch.
struct PipelineConfiguration: Sendable, Equatable {
    var preprocessing: PreprocessingEngine = .standardDSP
    var vad: VADEngine = .energyThreshold
    var languageDetection: LanguageDetectionEngine = .byTranscriber
    var diarization: DiarizationEngine = .fluidAudio
    /// Whether the user has consented to downloading the FluidAudio diarization
    /// models. Read together with `diarization` by `effectiveDiarization`.
    var diarizationConsented: Bool = false
    /// Whether the user has consented to downloading the sherpa-onnx
    /// diarization models. Same pairing as `diarizationConsented`, kept as a
    /// separate flag rather than one shared boolean because consenting to one
    /// engine's download must not be read as consent for the other's.
    var sherpaOnnxConsented: Bool = false
    var transcription: TranscriptionEngine = .appleSpeech
    /// Provider used by the `.whisperAPI` engine, chosen independently of the
    /// summary provider. Ignored by the on-device engines.
    var transcriptionProvider: AIProvider = .openAI
    /// Whisper model requested from `transcriptionProvider` (e.g. `whisper-1`,
    /// `whisper-large-v3`). Ignored by the on-device engines.
    var transcriptionModel: String = "whisper-1"
    var cloudTranscriptionConsented = false
    var largeTransferPolicy: LargeTransferPolicy = .wifiOnly
    var cloudTransfer: CloudTranscriptionTransfer {
        CloudTranscriptionTransfer(
            consented: cloudTranscriptionConsented,
            policy: largeTransferPolicy
        )
    }
    /// Exact number of speakers to pin on the FluidAudio diarizer (`0` = let it
    /// decide). Only the `.fluidAudio` engine reads it; a pinned count makes the
    /// pipeline re-cluster the raw speaker embeddings with KMeans instead of
    /// trusting its VBx step, which collapses to a single speaker on
    /// far-field/single-mic audio.
    var fluidAudioSpeakerCount: Int = 0
    /// When true, the diarization stage runs a dedicated lighter cleanup on the
    /// original recording (`DiarizationPreprocessor`) and feeds the resulting
    /// WAV to both diarizer engines. When false, diarization uses the original
    /// recording directly; it never reuses the ASR-cleaned `.m4a` produced by
    /// `AudioPreprocessor`.
    var diarizationPreprocessingEnabled: Bool = true
    /// GGML weight file the `.whisperCpp` engine loads. Ignored by every other
    /// engine.
    var whisperCppModel: WhisperCppModel = .default
    var correction: CorrectionEngine = .none
    /// Provider used by the `.llm` correction engine — the app's single summary
    /// provider (`AppSettings.aiProvider`), not a dedicated slot: there is
    /// exactly one summary-shaped `LLMProvider` in this app (see
    /// `ProviderFactory.summaryProvider`), reused for summaries/chat/wiki/
    /// auto-tagging/titles, and correction follows that precedent.
    var correctionProvider: AIProvider = .appleOnDevice
    var correctionModel: String = ""
    /// Whether the user opted in (Settings toggle) AND the correction provider
    /// is usable right now (`AIProvider.isUsable`: a configured API key for a
    /// cloud vendor, or a runnable model for the on-device provider). Read
    /// together with `correction` by `effectiveCorrection` — same
    /// fail-before-trying shape as `effectiveDiarization`, except the gate is
    /// "is this usable right now", not "has the user agreed to a model
    /// download" (only the on-device provider has a local model here, and it
    /// needs no download).
    var correctionConsented: Bool = false

    /// The correction engine that will actually run.
    var effectiveCorrection: CorrectionEngine {
        guard correction == .llm, correctionConsented else { return .none }
        return .llm
    }

    /// The diarizer that will actually run.
    ///
    /// `.fluidAudio` is the default because the heuristic engine is three scalars
    /// and a single greedy clustering pass, and it was what every user got who
    /// never opened Settings. But both the neural engines (`.fluidAudio` and
    /// `.sherpaOnnx`) download their models on first use, and downloading for a
    /// feature the user has not opted into is exactly what this app's consent
    /// design exists to prevent — and a failed download returns *one turn for
    /// the whole meeting*, which is worse than the heuristic, not better.
    ///
    /// So each downloadable choice is a pair with its own consent flag, not a
    /// single value: without consent the selection falls back rather than
    /// downloading or degrading silently. The caller reports the fallback so it
    /// can be acted on instead of merely being true.
    var effectiveDiarization: DiarizationEngine {
        switch diarization {
        case .heuristic: return .heuristic
        case .fluidAudio: return diarizationConsented ? .fluidAudio : .heuristic
        case .sherpaOnnx: return sherpaOnnxConsented ? .sherpaOnnx : .heuristic
        }
    }

    /// Whether `effectiveDiarization` had to step down from the user's choice.
    var diarizationFellBack: Bool {
        effectiveDiarization != diarization
    }
}

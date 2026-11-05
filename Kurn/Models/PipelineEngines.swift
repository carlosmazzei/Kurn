//
//  PipelineEngines.swift
//  Kurn
//
//  The engine choices for each transcription pipeline stage (see
//  `PipelineConfiguration`). `TranscriptionEngine` itself lives in KurnCore.
//

import Foundation
import KurnCore

// `TranscriptionMode` now lives in the KurnCore package
// (`Sources/KurnCore/Models/TranscriptionMode.swift`).

/// Speaker diarization engine used when transcribing a recording.
enum DiarizationEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Pitch/ZCR/spectral-tilt clustering, always available, no downloads.
    case heuristic
    /// FluidAudio's on-device diarization models (downloaded on first use).
    /// Clusters speaker embeddings first (VBx), which is what collapses to one
    /// speaker on far-field/single-mic audio — see `sherpaOnnx` below.
    case fluidAudio
    /// sherpa-onnx's on-device diarization models (downloaded on first use):
    /// segments who-is-speaking first (pyannote/segmentation-3.0), then
    /// clusters speaker embeddings (3D-Speaker CAM++). Structurally different
    /// failure mode from `fluidAudio`'s cluster-first VBx pipeline, offered as
    /// an alternative for recordings where that one collapses to one speaker.
    /// Runs on CPU only (no ANE acceleration), so it is slower than
    /// `fluidAudio` — a deliberate trade for collapse-resistance, not a
    /// straight upgrade.
    case sherpaOnnx
    /// Speaker labels returned natively by the selected `.whisperAPI`
    /// transcription provider's own response (e.g. ElevenLabs Scribe),
    /// instead of running a separate local diarization pass. Only honored
    /// when the transcription engine is `.whisperAPI` and the selected
    /// provider's `supportsNativeDiarization` is true — see
    /// `PipelineConfiguration.effectiveDiarization`, which falls back to
    /// `.heuristic` otherwise. No download, like `.heuristic`.
    case transcriptionProviderNative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heuristic: return NSLocalizedString("diarization.heuristic", comment: "Heuristic")
        case .fluidAudio: return NSLocalizedString("diarization.fluid_audio", comment: "FluidAudio")
        case .sherpaOnnx: return NSLocalizedString("diarization.sherpa_onnx", comment: "Sherpa-ONNX")
        case .transcriptionProviderNative:
            return NSLocalizedString(
                "diarization.transcription_provider_native",
                comment: "Transcription provider's native diarization"
            )
        }
    }

    /// Model family that must be downloaded before this engine runs, or `nil`
    /// when it needs no download.
    var requiredModelSet: ModelSet? {
        switch self {
        case .heuristic, .transcriptionProviderNative: return nil
        case .fluidAudio: return .diarization
        case .sherpaOnnx: return .sherpaOnnxDiarization
        }
    }
}

/// Opt-in LLM post-processing that corrects transcription errors (spelling,
/// punctuation, homophones, obvious ASR mistakes) after fusion. Cloud-only —
/// there is no on-device model for this stage, so unlike the other stage
/// enums it has no `requiredModelSet`.
enum CorrectionEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case llm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return NSLocalizedString("correction.none", comment: "No correction")
        case .llm: return NSLocalizedString("correction.llm", comment: "AI correction")
        }
    }
}

// `TranscriptionEngine` now lives in the KurnCore package
// (`Sources/KurnCore/Models/TranscriptionEngine.swift`); its
// `requiredModelSet(whisperCppModel:)` — which needs `ModelSet`, defined
// below in `ModelDownloadConsent.swift` and not portable — is added back as
// an extension in `Kurn/Models/TranscriptionEngine+ModelSet.swift`.

/// Offline DSP cleanup engine applied before the transcription path.
enum PreprocessingEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Speech-tuned filter chain (high-pass, presence EQ, measured makeup gain,
    /// limiter, mono 16 kHz).
    case standardDSP
    /// No cleanup — feed the original recording straight to the engines.
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standardDSP: return NSLocalizedString("preprocessing.standard", comment: "Standard cleanup")
        case .none: return NSLocalizedString("preprocessing.none", comment: "No cleanup")
        }
    }
}

/// Voice-activity detection engine used to find speech regions.
enum VADEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Energy-threshold (dBFS) detection over 100 ms frames. Always available.
    case energyThreshold
    /// FluidAudio's Silero VAD CoreML model. Requires a model download.
    case fluidAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .energyThreshold: return NSLocalizedString("vad.energy", comment: "Energy threshold")
        case .fluidAudio: return NSLocalizedString("vad.fluid_audio", comment: "FluidAudio (Silero)")
        }
    }

    var requiredModelSet: ModelSet? {
        switch self {
        case .energyThreshold: return nil
        case .fluidAudio: return .vad
        }
    }
}

/// Language-detection engine run before transcription to refine the language.
enum LanguageDetectionEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Defer to the transcription engine's own detection (current behavior).
    case byTranscriber
    /// FluidAudio Parakeet detects the language, then pins the locale so even
    /// `appleSpeech` benefits from auto-detection. Requires a model download.
    case fluidAudioLID

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .byTranscriber: return NSLocalizedString("langdetect.by_transcriber", comment: "By transcriber")
        case .fluidAudioLID: return NSLocalizedString("langdetect.fluid_lid", comment: "FluidAudio detection")
        }
    }

    var requiredModelSet: ModelSet? {
        switch self {
        case .byTranscriber: return nil
        case .fluidAudioLID: return .onDeviceASR
        }
    }
}

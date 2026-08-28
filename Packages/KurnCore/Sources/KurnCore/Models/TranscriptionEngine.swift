//
//  TranscriptionEngine.swift
//  KurnCore
//
//  Transcription engine used to turn audio into text. Replaces the older
//  `TranscriptionMode` + "multilingual on-device" boolean pair with a single
//  explicit choice. `TranscriptionMode` is still persisted on `Recording` for
//  back-compat; map via `storageMode`.
//
//  `requiredModelSet(whisperCppModel:)` is NOT here: it returns `ModelSet`,
//  which lives in `Kurn/Infrastructure/ModelDownloadConsent.swift` and
//  orchestrates actual FluidAudio/whisper.cpp downloads — not portable, and
//  out of scope for this package. The app adds it back as an extension
//  (`Kurn/Models/TranscriptionEngine+ModelSet.swift`), which is possible
//  because Swift extensions can add methods to a type from another module.
//

import Foundation

public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple `SFSpeechRecognizer`, on-device, fixed locale (no language detection).
    case appleSpeech
    /// FluidAudio multilingual on-device batch ASR (Parakeet TDT v3), detects
    /// the spoken language from the audio. Requires a model download.
    case fluidAudioParakeet
    /// OpenAI Whisper cloud API (chunked upload). Requires an OpenAI API key.
    case whisperAPI
    /// Whisper running fully on device through whisper.cpp. Same language
    /// coverage as `.whisperAPI` with nothing leaving the phone, at the cost of
    /// a one-time GGML weight download (see `WhisperCppModel`).
    case whisperCpp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSpeech: return NSLocalizedString("transcription.apple_speech", comment: "Apple Speech")
        case .fluidAudioParakeet: return NSLocalizedString("transcription.fluid_parakeet", comment: "FluidAudio multilingual")
        case .whisperAPI: return NSLocalizedString("transcription.whisper", comment: "Whisper API")
        case .whisperCpp: return NSLocalizedString("transcription.whisper_cpp", comment: "Whisper on-device")
        }
    }

    /// The legacy `TranscriptionMode` to persist on `Recording` so the stored
    /// field stays valid without a SwiftData migration.
    public var storageMode: TranscriptionMode {
        switch self {
        case .appleSpeech, .fluidAudioParakeet, .whisperCpp: return .onDevice
        case .whisperAPI: return .whisperAPI
        }
    }
}

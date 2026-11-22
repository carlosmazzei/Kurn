//
//  TranscriptionPreset.swift
//  Kurn
//
//  The four named pipeline configurations behind Transcription settings'
//  Simple mode. Each preset fixes the engine, the cloud provider/model when
//  the engine is remote, the diarization stage and the preprocessing/VAD
//  stages; `matching` recognizes the same fields so the hub can name the
//  active preset and Simple mode can mark it.
//

import Foundation
import KurnCore

/// The pipeline fields a preset pins down. Everything not listed —
/// default language, correction, network transfer — stays the user's.
struct TranscriptionPipelineChoice: Equatable {
    var engine: TranscriptionEngine
    var asrModel: FluidAudioASRModel?
    /// The built-in provider's `id` ("elevenLabs", "groq"), not its kind:
    /// Groq shares `.openAICompatible` with OpenAI, so the kind alone
    /// cannot name the preset's provider.
    var cloudProviderID: String?
    var cloudModel: String?
    var diarization: DiarizationEngine
    var diarizationModel: FluidAudioDiarizationModel?
    var preprocessing: PreprocessingEngine
    var vad: VADEngine
}

enum TranscriptionPreset: String, CaseIterable, Identifiable {
    case bestQuality
    case bestOnDevice
    case fastCloud
    case basic

    var id: String { rawValue }

    func choice(for language: MeetingLanguage) -> TranscriptionPipelineChoice {
        switch self {
        case .bestQuality:
            return TranscriptionPipelineChoice(
                engine: .whisperAPI,
                asrModel: nil,
                cloudProviderID: AIProvider.elevenLabs.id,
                cloudModel: "scribe_v2",
                diarization: .transcriptionProviderNative,
                diarizationModel: nil,
                preprocessing: .none,
                vad: .fluidAudio
            )
        case .bestOnDevice:
            return TranscriptionPipelineChoice(
                engine: .fluidAudioParakeet,
                asrModel: language == .portuguese ? .nemotronUnified : .parakeetV3,
                cloudProviderID: nil,
                cloudModel: nil,
                diarization: .fluidAudio,
                diarizationModel: .nemotron3,
                preprocessing: .standardDSP,
                vad: .energyThreshold
            )
        case .fastCloud:
            return TranscriptionPipelineChoice(
                engine: .whisperAPI,
                asrModel: nil,
                cloudProviderID: AIProvider.groq.id,
                cloudModel: "whisper-large-v3-turbo",
                diarization: .fluidAudio,
                diarizationModel: .pyannote,
                preprocessing: .standardDSP,
                vad: .energyThreshold
            )
        case .basic:
            return TranscriptionPipelineChoice(
                engine: .appleSpeech,
                asrModel: nil,
                cloudProviderID: nil,
                cloudModel: nil,
                diarization: .heuristic,
                diarizationModel: nil,
                preprocessing: .standardDSP,
                vad: .energyThreshold
            )
        }
    }

    /// Only the fields a preset sets are compared; `cloudModel` matches
    /// case- and whitespace-insensitively since providers list their own
    /// casing.
    static func matching(_ choice: TranscriptionPipelineChoice, language: MeetingLanguage) -> TranscriptionPreset? {
        allCases.first { preset in
            let expected = preset.choice(for: language)
            return expected.engine == choice.engine
                && expected.asrModel == choice.asrModel
                && expected.cloudProviderID == choice.cloudProviderID
                && normalized(expected.cloudModel) == normalized(choice.cloudModel)
                && expected.diarization == choice.diarization
                && expected.diarizationModel == choice.diarizationModel
                && expected.preprocessing == choice.preprocessing
                && expected.vad == choice.vad
        }
    }

    private static func normalized(_ model: String?) -> String? {
        model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One gated field of a preset application, in the order the view drives
    /// it: each step maps to one consent path (cloud upload dialog for
    /// `cloudProvider`/`engine` when remote, a model-download prompt for the
    /// rest), so the pending preset can resume where it stopped.
    enum PendingStep: Equatable {
        case cloudProvider, asrModel, diarizationModel, engine, diarization, vad
    }

    /// The first field where `current` still differs from `target`, in
    /// pending-step order. `nil` means every gated field is already applied
    /// and only the ungated leftovers (cloud model, preprocessing) remain.
    static func nextUnmetStep(
        target: TranscriptionPipelineChoice,
        current: TranscriptionPipelineChoice
    ) -> PendingStep? {
        if let provider = target.cloudProviderID, current.cloudProviderID != provider {
            return .cloudProvider
        }
        if let model = target.asrModel, current.asrModel != model { return .asrModel }
        if let model = target.diarizationModel, current.diarizationModel != model {
            return .diarizationModel
        }
        if current.engine != target.engine { return .engine }
        if current.diarization != target.diarization { return .diarization }
        if current.vad != target.vad { return .vad }
        return nil
    }
}

extension TranscriptionPreset {
    /// The localization key stem — the enum's camelCase `rawValue` doesn't
    /// match the snake_case string keys, so map explicitly.
    private var stringKey: String {
        switch self {
        case .bestQuality: return "best_quality"
        case .bestOnDevice: return "best_on_device"
        case .fastCloud: return "fast_cloud"
        case .basic: return "basic"
        }
    }

    var titleKey: String { "settings.preset.\(stringKey).title" }
    var subtitleKey: String { "settings.preset.\(stringKey).subtitle" }

    var title: String { NSLocalizedString(titleKey, comment: "Transcription preset name") }
    var subtitle: String { NSLocalizedString(subtitleKey, comment: "Transcription preset subtitle") }

    /// The key/value rows shown inside the preset's card.
    var cardRows: [(label: String, value: String)] {
        func row(_ labelKey: String, _ value: String) -> (String, String) {
            (NSLocalizedString(labelKey, comment: "Preset fact label"), value)
        }
        func v(_ key: String) -> String {
            NSLocalizedString("settings.preset.\(stringKey).\(key)", comment: "Transcription preset fact")
        }
        switch self {
        case .bestQuality:
            return [
                row("settings.preset.english", v("v_english")),
                row("settings.preset.who_spoke", v("v_who")),
                row("settings.preset.portuguese", v("v_portuguese")),
                row("settings.preset.needs", v("v_needs"))
            ]
        case .bestOnDevice:
            return [
                row("settings.preset.english", v("v_english")),
                row("settings.preset.who_spoke", v("v_who")),
                row("settings.preset.portuguese", v("v_portuguese")),
                row("settings.preset.needs", v("v_needs"))
            ]
        case .fastCloud:
            return [
                row("settings.preset.english", v("v_english")),
                row("settings.preset.portuguese", v("v_portuguese")),
                row("settings.preset.needs", v("v_needs"))
            ]
        case .basic:
            return [
                row("settings.preset.quality", v("v_quality")),
                row("settings.preset.needs", v("v_needs"))
            ]
        }
    }
}

extension TranscriptionPipelineChoice {
    /// The pipeline as it is currently configured in `AppSettings`. Cloud
    /// provider/model only count while the engine is remote — a stale stored
    /// provider must not stop an on-device preset from matching.
    @MainActor
    init(settings: AppSettings) {
        engine = settings.transcriptionEngine
        asrModel = settings.fluidAudioASRModel
        diarization = settings.diarizationEngine
        diarizationModel = settings.fluidAudioDiarizationModel
        preprocessing = settings.preprocessingEngine
        vad = settings.vadEngine
        if settings.transcriptionEngine == .whisperAPI {
            cloudProviderID = settings.transcriptionProviderID
            cloudModel = settings.transcriptionModel(for: settings.transcriptionProvider)
        } else {
            cloudProviderID = nil
            cloudModel = nil
        }
    }
}

extension TranscriptionPreset {
    /// The preset matching the current configuration, if any.
    @MainActor
    static func current(settings: AppSettings) -> TranscriptionPreset? {
        matching(TranscriptionPipelineChoice(settings: settings), language: settings.defaultLanguage)
    }
}

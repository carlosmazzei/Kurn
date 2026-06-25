//
//  AppSettings.swift
//  Kurn
//
//  Observable, UserDefaults-backed app preferences. API keys are NOT stored here
//  — they live in the Keychain (see KeychainManager). Only non-secret defaults
//  belong in this file.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let provider = "settings.aiProvider"
        static let providers = "settings.aiProviders"
        static let defaultMode = "settings.defaultTranscriptionMode"
        static let defaultLanguage = "settings.defaultLanguage"
        static let micPickup = "settings.micPickup"
        static let audioQuality = "settings.audioQuality"
        static let summaryModels = "settings.summaryModels"
        static let summaryTemplates = "settings.summaryTemplates"
        static let lastSummaryTemplate = "settings.lastSummaryTemplate"
        static let liveTranscriptionEnabled = "settings.liveTranscriptionEnabled"
        static let diarizationEngine = "settings.diarizationEngine"
        static let transcriptionEngine = "settings.transcriptionEngine"
        static let preprocessingEngine = "settings.preprocessingEngine"
        static let vadEngine = "settings.vadEngine"
        static let languageDetectionEngine = "settings.languageDetectionEngine"
        static let fluidAudioASRModelsConsented = "settings.fluidAudioASRModelsConsented"
        static let fluidAudioBatchASRModelsConsented = "settings.fluidAudioBatchASRModelsConsented"
        static let fluidAudioDiarizationModelsConsented = "settings.fluidAudioDiarizationModelsConsented"
        static let fluidAudioVADModelsConsented = "settings.fluidAudioVADModelsConsented"
        static let logLevel = "settings.logLevel"
    }

    private let defaults = UserDefaults.standard

    var providers: [AIProvider] {
        didSet { persistProviders() }
    }

    var aiProviderID: String {
        didSet { defaults.set(aiProviderID, forKey: Keys.provider) }
    }

    var aiProvider: AIProvider {
        providers.first(where: { $0.id == aiProviderID }) ?? providers.first ?? .openAI
    }

    var defaultMode: TranscriptionMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Keys.defaultMode) }
    }

    var defaultLanguage: MeetingLanguage {
        didSet { defaults.set(defaultLanguage.rawValue, forKey: Keys.defaultLanguage) }
    }

    /// Built-in microphone pickup preference. Defaults to whole-room capture.
    var micPickup: MicPickup {
        didSet { defaults.set(micPickup.rawValue, forKey: Keys.micPickup) }
    }

    /// Recording audio quality (encoder bit rate). Defaults to high.
    var audioQuality: AudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: Keys.audioQuality) }
    }

    /// Opt-in live transcription preview during recording (FluidAudio streaming
    /// ASR). Off by default; never replaces the post-recording transcript.
    var liveTranscriptionEnabled: Bool {
        didSet { defaults.set(liveTranscriptionEnabled, forKey: Keys.liveTranscriptionEnabled) }
    }

    /// Speaker diarization engine used by the transcription pipeline. Defaults
    /// to the always-available heuristic engine.
    var diarizationEngine: DiarizationEngine {
        didSet { defaults.set(diarizationEngine.rawValue, forKey: Keys.diarizationEngine) }
    }

    /// Engine that turns audio into text. Replaces the legacy `defaultMode` +
    /// on-device-multilingual pairing; `init` migrates the old keys into this.
    var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// Offline audio-cleanup engine applied before transcription/diarization.
    var preprocessingEngine: PreprocessingEngine {
        didSet { defaults.set(preprocessingEngine.rawValue, forKey: Keys.preprocessingEngine) }
    }

    /// Voice-activity-detection engine used for speech-region segmentation.
    var vadEngine: VADEngine {
        didSet { defaults.set(vadEngine.rawValue, forKey: Keys.vadEngine) }
    }

    /// Language-detection engine run before transcription to refine the language.
    var languageDetectionEngine: LanguageDetectionEngine {
        didSet { defaults.set(languageDetectionEngine.rawValue, forKey: Keys.languageDetectionEngine) }
    }

    /// The full per-stage pipeline configuration assembled from the individual
    /// engine preferences, passed to `TranscriptionService`.
    var pipelineConfiguration: PipelineConfiguration {
        PipelineConfiguration(
            preprocessing: preprocessingEngine,
            vad: vadEngine,
            languageDetection: languageDetectionEngine,
            diarization: diarizationEngine,
            transcription: transcriptionEngine
        )
    }

    /// Whether the user has consented to downloading FluidAudio's streaming ASR
    /// models (independent of the diarization model consent below).
    var fluidAudioASRModelsConsented: Bool {
        didSet { defaults.set(fluidAudioASRModelsConsented, forKey: Keys.fluidAudioASRModelsConsented) }
    }

    /// Whether the user has consented to downloading FluidAudio's multilingual
    /// on-device batch ASR model (Parakeet TDT v3). When enabled, "Auto" meetings
    /// transcribed on-device detect the language from the audio instead of
    /// falling back to Apple Speech with the device locale.
    var fluidAudioBatchASRModelsConsented: Bool {
        didSet { defaults.set(fluidAudioBatchASRModelsConsented, forKey: Keys.fluidAudioBatchASRModelsConsented) }
    }

    /// Whether the user has consented to downloading FluidAudio's diarization
    /// models (independent of the ASR model consent above).
    var fluidAudioDiarizationModelsConsented: Bool {
        didSet { defaults.set(fluidAudioDiarizationModelsConsented, forKey: Keys.fluidAudioDiarizationModelsConsented) }
    }

    /// Whether the user has consented to downloading FluidAudio's Silero VAD
    /// model (used by the FluidAudio voice-activity-detection engine).
    var fluidAudioVADModelsConsented: Bool {
        didSet { defaults.set(fluidAudioVADModelsConsented, forKey: Keys.fluidAudioVADModelsConsented) }
    }

    /// Minimum severity emitted by `AppLog`. Persisted here and pushed to
    /// `AppLog.minimumLevel` so the choice survives relaunches. `.off` disables
    /// all app logging.
    var logLevel: LogLevel {
        didSet {
            defaults.set(logLevel.rawValue, forKey: Keys.logLevel)
            AppLog.minimumLevel = logLevel
        }
    }

    /// Per-provider chosen summary model (rawValue → model id).
    private var summaryModels: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(summaryModels) {
                defaults.set(data, forKey: Keys.summaryModels)
            }
        }
    }

    /// Selected summary model for a provider, falling back to its default.
    func summaryModel(for provider: AIProvider) -> String {
        let stored = summaryModels[provider.rawValue]
        if let stored, !stored.isEmpty { return stored }
        return provider.defaultModel
    }

    func setSummaryModel(_ model: String, for provider: AIProvider) {
        summaryModels[provider.rawValue] = model
    }

    /// Summary templates (built-in presets + user-defined). Built-ins are seeded
    /// from `SummaryTemplate.defaultTemplates` and merged on launch.
    var summaryTemplates: [SummaryTemplate] {
        didSet { persistTemplates() }
    }

    /// Id of the template chosen for the most recent summary, used to preselect
    /// the picker. Falls back to the first available template.
    var lastSummaryTemplateID: String {
        didSet { defaults.set(lastSummaryTemplateID, forKey: Keys.lastSummaryTemplate) }
    }

    func template(for id: String) -> SummaryTemplate? {
        summaryTemplates.first(where: { $0.id == id })
    }

    func addTemplate(_ template: SummaryTemplate) {
        summaryTemplates.append(template)
    }

    func updateTemplate(_ template: SummaryTemplate) {
        guard let index = summaryTemplates.firstIndex(where: { $0.id == template.id }) else { return }
        summaryTemplates[index] = template
    }

    func removeTemplate(_ template: SummaryTemplate) {
        guard !template.isBuiltIn else { return }
        summaryTemplates.removeAll { $0.id == template.id }
        if lastSummaryTemplateID == template.id {
            lastSummaryTemplateID = summaryTemplates.first?.id ?? SummaryTemplate.general.id
        }
    }

    func addProvider(_ provider: AIProvider) {
        providers.append(provider)
        aiProviderID = provider.id
    }

    func updateProvider(_ provider: AIProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }

    func removeProvider(_ provider: AIProvider) {
        guard !provider.isBuiltIn else { return }
        providers.removeAll { $0.id == provider.id }
        summaryModels[provider.id] = nil
        KeychainManager.shared.delete(provider.keychainAccount)
        if aiProviderID == provider.id {
            aiProviderID = providers.first?.id ?? AIProvider.openAI.id
        }
    }

    init() {
        let loadedProviders: [AIProvider]
        if let data = defaults.data(forKey: Keys.providers),
           let decoded = try? JSONDecoder().decode([AIProvider].self, from: data),
           !decoded.isEmpty {
            loadedProviders = Self.mergedProviders(decoded)
        } else {
            loadedProviders = AIProvider.defaultProviders
        }
        providers = loadedProviders
        let storedProviderID = defaults.string(forKey: Keys.provider) ?? AIProvider.openAI.id
        aiProviderID = loadedProviders.contains(where: { $0.id == storedProviderID })
            ? storedProviderID
            : AIProvider.openAI.id
        defaultMode = TranscriptionMode(
            rawValue: defaults.string(forKey: Keys.defaultMode) ?? ""
        ) ?? .onDevice
        defaultLanguage = MeetingLanguage(
            rawValue: defaults.string(forKey: Keys.defaultLanguage) ?? ""
        ) ?? .autoDetect
        micPickup = MicPickup(
            rawValue: defaults.string(forKey: Keys.micPickup) ?? ""
        ) ?? .wholeRoom
        audioQuality = AudioQuality(
            rawValue: defaults.string(forKey: Keys.audioQuality) ?? ""
        ) ?? .high
        liveTranscriptionEnabled = defaults.bool(forKey: Keys.liveTranscriptionEnabled)
        diarizationEngine = DiarizationEngine(
            rawValue: defaults.string(forKey: Keys.diarizationEngine) ?? ""
        ) ?? .heuristic
        fluidAudioASRModelsConsented = defaults.bool(forKey: Keys.fluidAudioASRModelsConsented)
        fluidAudioBatchASRModelsConsented = defaults.bool(forKey: Keys.fluidAudioBatchASRModelsConsented)
        fluidAudioDiarizationModelsConsented = defaults.bool(forKey: Keys.fluidAudioDiarizationModelsConsented)
        fluidAudioVADModelsConsented = defaults.bool(forKey: Keys.fluidAudioVADModelsConsented)
        // Transcription engine: prefer the stored value; otherwise migrate the
        // legacy `defaultMode` + on-device-multilingual pairing into the new
        // single explicit choice.
        let storedTranscriptionEngine = (defaults.string(forKey: Keys.transcriptionEngine))
            .flatMap(TranscriptionEngine.init(rawValue:))
        transcriptionEngine = storedTranscriptionEngine
            ?? Self.migratedTranscriptionEngine(
                mode: defaultMode,
                language: defaultLanguage,
                multilingualConsented: fluidAudioBatchASRModelsConsented
            )
        preprocessingEngine = PreprocessingEngine(
            rawValue: defaults.string(forKey: Keys.preprocessingEngine) ?? ""
        ) ?? .standardDSP
        vadEngine = VADEngine(
            rawValue: defaults.string(forKey: Keys.vadEngine) ?? ""
        ) ?? .energyThreshold
        languageDetectionEngine = LanguageDetectionEngine(
            rawValue: defaults.string(forKey: Keys.languageDetectionEngine) ?? ""
        ) ?? .byTranscriber
        // Fall back to the environment-derived default (set on `AppLog` at
        // launch) when the user hasn't chosen a level yet.
        let resolvedLogLevel = (defaults.string(forKey: Keys.logLevel))
            .flatMap(LogLevel.init(rawValue:)) ?? AppLog.minimumLevel
        logLevel = resolvedLogLevel
        AppLog.minimumLevel = resolvedLogLevel
        if let data = defaults.data(forKey: Keys.summaryModels),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            summaryModels = decoded
        } else {
            summaryModels = [:]
        }
        let loadedTemplates: [SummaryTemplate]
        if let data = defaults.data(forKey: Keys.summaryTemplates),
           let decoded = try? JSONDecoder().decode([SummaryTemplate].self, from: data),
           !decoded.isEmpty {
            loadedTemplates = Self.mergedTemplates(decoded)
        } else {
            loadedTemplates = SummaryTemplate.defaultTemplates
        }
        summaryTemplates = loadedTemplates
        let storedTemplateID = defaults.string(forKey: Keys.lastSummaryTemplate)
            ?? SummaryTemplate.general.id
        lastSummaryTemplateID = loadedTemplates.contains(where: { $0.id == storedTemplateID })
            ? storedTemplateID
            : (loadedTemplates.first?.id ?? SummaryTemplate.general.id)
    }

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Keys.providers)
        }
    }

    private func persistTemplates() {
        if let data = try? JSONEncoder().encode(summaryTemplates) {
            defaults.set(data, forKey: Keys.summaryTemplates)
        }
    }

    /// Keep stored templates (user edits to built-ins persist) and append any
    /// built-in preset that isn't present yet, so new presets appear on upgrade.
    private static func mergedTemplates(_ stored: [SummaryTemplate]) -> [SummaryTemplate] {
        var templates = stored
        for builtIn in SummaryTemplate.defaultTemplates
        where !templates.contains(where: { $0.id == builtIn.id }) {
            templates.append(builtIn)
        }
        return templates
    }

    /// Derive the initial `TranscriptionEngine` from the legacy `defaultMode` +
    /// on-device-multilingual consent so upgrading users keep their behavior.
    static func migratedTranscriptionEngine(
        mode: TranscriptionMode,
        language: MeetingLanguage,
        multilingualConsented: Bool
    ) -> TranscriptionEngine {
        switch mode {
        case .whisperAPI:
            return .whisperAPI
        case .onDevice:
            // The old "Auto + multilingual model consented" path routed to
            // FluidAudio Parakeet; everything else used Apple Speech.
            return (language == .autoDetect && multilingualConsented) ? .fluidAudioParakeet : .appleSpeech
        }
    }

    private static func mergedProviders(_ stored: [AIProvider]) -> [AIProvider] {
        var providers = AIProvider.defaultProviders
        for provider in stored where !provider.isBuiltIn && !providers.contains(where: { $0.id == provider.id }) {
            providers.append(provider)
        }
        return providers
    }
}

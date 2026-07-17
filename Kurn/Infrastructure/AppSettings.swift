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

/// UserDefaults key for diagnostic-reports consent, hoisted out of `AppSettings.Keys`
/// (which is `private`) so `DiagnosticsSubscriber` can read it directly without
/// holding an `AppSettings` reference — see that type for why.
enum AppSettingsKeys {
    static let diagnosticReportsConsented = "settings.diagnosticReportsConsented"
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let provider = "settings.aiProvider"
        static let providers = "settings.aiProviders"
        static let transcriptionProvider = "settings.transcriptionProviderID"
        static let transcriptionModels = "settings.transcriptionModels"
        static let defaultMode = "settings.defaultTranscriptionMode"
        static let defaultLanguage = "settings.defaultLanguage"
        static let micPickup = "settings.micPickup"
        static let audioQuality = "settings.audioQuality"
        static let summaryModels = "settings.summaryModels"
        static let summaryTemplates = "settings.summaryTemplates"
        static let lastSummaryTemplate = "settings.lastSummaryTemplate"
        static let liveTranscriptionEnabled = "settings.liveTranscriptionEnabled"
        static let diarizationEngine = "settings.diarizationEngine"
        static let fluidAudioMinSpeakers = "settings.fluidAudioMinSpeakers"
        static let diarizationPreprocessingEnabled = "settings.diarizationPreprocessingEnabled"
        static let transcriptionEngine = "settings.transcriptionEngine"
        static let preprocessingEngine = "settings.preprocessingEngine"
        static let vadEngine = "settings.vadEngine"
        static let languageDetectionEngine = "settings.languageDetectionEngine"
        static let fluidAudioASRModelsConsented = "settings.fluidAudioASRModelsConsented"
        static let fluidAudioBatchASRModelsConsented = "settings.fluidAudioBatchASRModelsConsented"
        static let fluidAudioDiarizationModelsConsented = "settings.fluidAudioDiarizationModelsConsented"
        static let fluidAudioVADModelsConsented = "settings.fluidAudioVADModelsConsented"
        static let logLevel = "settings.logLevel"
        static let requireAuthForRecordings = "settings.requireAuthForRecordings"
        static let hideLiveActivityMeetingTitle = "settings.hideLiveActivityMeetingTitle"
        static let meetingsSortOrder = "settings.meetingsSortOrder"
        static let autoTaggingEnabled = "settings.autoTaggingEnabled"
        static let usageStats = "settings.usageStats"
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

    /// Provider used for cloud (Whisper) transcription, chosen independently of
    /// the summary `aiProvider`. Only meaningful when `transcriptionEngine` is
    /// `.whisperAPI`. Defaults to OpenAI to preserve the previous behavior.
    var transcriptionProviderID: String {
        didSet { defaults.set(transcriptionProviderID, forKey: Keys.transcriptionProvider) }
    }

    /// Resolve `transcriptionProviderID` to a configured provider, falling back
    /// to the first transcription-capable provider (or OpenAI) if it's stale or
    /// points at a provider that can't transcribe.
    var transcriptionProvider: AIProvider {
        if let provider = providers.first(where: { $0.id == transcriptionProviderID }),
           provider.supportsTranscription {
            return provider
        }
        return providers.first(where: { $0.supportsTranscription }) ?? .openAI
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

    /// How the meetings list is sorted. Defaults to newest first to match the
    /// previous hard-coded behavior. See `MeetingsSortOrder.apply(to:)`.
    var meetingsSortOrder: MeetingsSortOrder {
        didSet { defaults.set(meetingsSortOrder.rawValue, forKey: Keys.meetingsSortOrder) }
    }

    /// Whether auto-tagging is enabled. When on, the app can suggest tags after
    /// a transcription finishes and the user can apply them with one tap.
    var autoTaggingEnabled: Bool {
        didSet { defaults.set(autoTaggingEnabled, forKey: Keys.autoTaggingEnabled) }
    }

    /// Opt-in live transcription preview during recording (FluidAudio streaming
    /// ASR). Off by default; never replaces the post-recording transcript.
    var liveTranscriptionEnabled: Bool {
        didSet { defaults.set(liveTranscriptionEnabled, forKey: Keys.liveTranscriptionEnabled) }
    }

    /// When on, the recordings UI requires Face ID / Touch ID / passcode once
    /// per foreground session before listing meetings or playing audio. Audio
    /// files are always encrypted at rest by iOS Data Protection regardless
    /// of this toggle. Defaults to on so the secure path is the default.
    var requireAuthForRecordings: Bool {
        didSet { defaults.set(requireAuthForRecordings, forKey: Keys.requireAuthForRecordings) }
    }

    /// When on, the Lock Screen / Dynamic Island Live Activity shows a generic
    /// "Recording…" label instead of the real meeting title, since the Live
    /// Activity is visible to anyone glancing at a locked phone. Defaults to
    /// on so the private option is the default.
    var hideLiveActivityMeetingTitle: Bool {
        didSet {
            defaults.set(hideLiveActivityMeetingTitle, forKey: Keys.hideLiveActivityMeetingTitle)
        }
    }

    /// Speaker diarization engine used by the transcription pipeline. Defaults
    /// to the always-available heuristic engine.
    var diarizationEngine: DiarizationEngine {
        didSet { defaults.set(diarizationEngine.rawValue, forKey: Keys.diarizationEngine) }
    }

    /// Minimum number of speakers to force on the FluidAudio (neural) diarizer.
    /// `0` means auto-detect (no constraint). On far-field/single-mic audio the
    /// neural pipeline's VBx step collapses every cluster into one speaker; a
    /// non-zero floor here makes FluidAudio re-cluster with KMeans to at least
    /// this many speakers instead of reporting a single one. Ignored by the
    /// heuristic engine, which auto-detects from pitch/timbre.
    var fluidAudioMinSpeakers: Int {
        didSet { defaults.set(fluidAudioMinSpeakers, forKey: Keys.fluidAudioMinSpeakers) }
    }

    /// When on, the diarization stage runs a dedicated lighter cleanup
    /// (`DiarizationPreprocessor`) on the original recording and feeds the
    /// resulting WAV to both diarizer engines. When off, diarization uses the
    /// original recording directly. It never reuses the ASR-tuned `.m4a`
    /// produced by `AudioPreprocessor`.
    var diarizationPreprocessingEnabled: Bool {
        didSet { defaults.set(diarizationPreprocessingEnabled, forKey: Keys.diarizationPreprocessingEnabled) }
    }

    /// Engine that turns audio into text. Replaces the legacy `defaultMode` +
    /// on-device-multilingual pairing; `init` migrates the old keys into this.
    var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// Offline audio-cleanup engine applied before the transcription path.
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
            transcription: transcriptionEngine,
            transcriptionProvider: transcriptionProvider,
            transcriptionModel: transcriptionModel(for: transcriptionProvider),
            fluidAudioMinSpeakers: fluidAudioMinSpeakers,
            diarizationPreprocessingEnabled: diarizationPreprocessingEnabled
        )
    }

    /// Whether the selected pipeline relies on the FluidAudio on-device ASR model
    /// (as the Parakeet transcriber or the auto-language detector) *and* the user
    /// has consented to downloading it. Gates foreground pre-warming so the model
    /// is only loaded for users who will actually use it, and never downloaded
    /// without consent. See `FluidAudioModelStore.prewarm()`.
    var usesFluidAudioModel: Bool {
        let needsOnDeviceASR = transcriptionEngine.requiredModelSet == .onDeviceASR
            || languageDetectionEngine.requiredModelSet == .onDeviceASR
        return needsOnDeviceASR && fluidAudioBatchASRModelsConsented
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

    /// Whether the user has opted in to on-device MetricKit diagnostic reports
    /// (crashes + hangs). Off by default: until this is `true`,
    /// `DiagnosticsSubscriber` discards every payload it receives instead of
    /// persisting it, so nothing is captured without explicit consent. Even
    /// when on, nothing leaves the device automatically — reports only leave
    /// via an explicit "Share" action on a specific report.
    var diagnosticReportsConsented: Bool {
        didSet {
            defaults.set(diagnosticReportsConsented, forKey: AppSettingsKeys.diagnosticReportsConsented)
        }
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

    /// Local-only usage counters (recordings completed, engine/template usage),
    /// shown read-only in the "My Data" screen. Never transmitted anywhere.
    private var usageStats: UsageStats {
        didSet {
            if let data = try? JSONEncoder().encode(usageStats) {
                defaults.set(data, forKey: Keys.usageStats)
            }
        }
    }

    /// Read-only snapshot for the "My Data" screen.
    var usageStatsSnapshot: UsageStats { usageStats }

    func recordRecordingCompleted() {
        usageStats.recordingsCompleted += 1
    }

    func recordTranscriptionEngineUsed(_ engine: TranscriptionEngine) {
        usageStats.transcriptionEngineUsage[engine.rawValue, default: 0] += 1
    }

    func recordSummaryTemplateUsed(_ templateID: String) {
        usageStats.summaryTemplateUsage[templateID, default: 0] += 1
    }

    /// Clear every local usage counter. Surfaced as "Clear my data" on the
    /// usage insights screen.
    func resetUsageStats() {
        usageStats = UsageStats()
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

    /// Per-provider chosen transcription (Whisper) model (rawValue → model id).
    private var transcriptionModels: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(transcriptionModels) {
                defaults.set(data, forKey: Keys.transcriptionModels)
            }
        }
    }

    /// Selected transcription model for a provider, falling back to its default
    /// Whisper model (`whisper-1`, or `whisper-large-v3` for Groq).
    func transcriptionModel(for provider: AIProvider) -> String {
        let stored = transcriptionModels[provider.rawValue]
        if let stored, !stored.isEmpty { return stored }
        return provider.defaultTranscriptionModel
    }

    func setTranscriptionModel(_ model: String, for provider: AIProvider) {
        transcriptionModels[provider.rawValue] = model
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
        transcriptionModels[provider.id] = nil
        KeychainManager.shared.delete(provider.keychainAccount)
        if aiProviderID == provider.id {
            aiProviderID = providers.first?.id ?? AIProvider.openAI.id
        }
        if transcriptionProviderID == provider.id {
            transcriptionProviderID = providers.first(where: { $0.supportsTranscription })?.id
                ?? AIProvider.openAI.id
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
        let storedTranscriptionProviderID = defaults.string(forKey: Keys.transcriptionProvider)
            ?? AIProvider.openAI.id
        transcriptionProviderID = loadedProviders.contains(where: {
            $0.id == storedTranscriptionProviderID && $0.supportsTranscription
        }) ? storedTranscriptionProviderID : AIProvider.openAI.id
        let resolvedDefaultMode = TranscriptionMode(
            rawValue: defaults.string(forKey: Keys.defaultMode) ?? ""
        ) ?? .onDevice
        defaultMode = resolvedDefaultMode
        let resolvedDefaultLanguage = MeetingLanguage(
            rawValue: defaults.string(forKey: Keys.defaultLanguage) ?? ""
        ) ?? .autoDetect
        defaultLanguage = resolvedDefaultLanguage
        micPickup = MicPickup(
            rawValue: defaults.string(forKey: Keys.micPickup) ?? ""
        ) ?? .wholeRoom
        audioQuality = AudioQuality(
            rawValue: defaults.string(forKey: Keys.audioQuality) ?? ""
        ) ?? .high
        meetingsSortOrder = MeetingsSortOrder(
            rawValue: defaults.string(forKey: Keys.meetingsSortOrder) ?? ""
        ) ?? .dateNewest
        autoTaggingEnabled = defaults.object(forKey: Keys.autoTaggingEnabled) as? Bool ?? false
        liveTranscriptionEnabled = defaults.bool(forKey: Keys.liveTranscriptionEnabled)
        // `object(forKey:)` so an absent key defaults to `true` rather than
        // `false` (which is what `defaults.bool(forKey:)` would return).
        requireAuthForRecordings = defaults.object(forKey: Keys.requireAuthForRecordings) as? Bool ?? true
        // `object(forKey:)` so an absent key defaults to `true` rather than
        // `false` (which is what `defaults.bool(forKey:)` would return).
        hideLiveActivityMeetingTitle = defaults.object(forKey: Keys.hideLiveActivityMeetingTitle) as? Bool ?? true
        diarizationEngine = DiarizationEngine(
            rawValue: defaults.string(forKey: Keys.diarizationEngine) ?? ""
        ) ?? .heuristic
        fluidAudioMinSpeakers = defaults.integer(forKey: Keys.fluidAudioMinSpeakers)
        // `object(forKey:)` so an absent key defaults to `true` rather than
        // `false` (which is what `defaults.bool(forKey:)` would return).
        diarizationPreprocessingEnabled = defaults.object(forKey: Keys.diarizationPreprocessingEnabled) as? Bool ?? true
        fluidAudioASRModelsConsented = defaults.bool(forKey: Keys.fluidAudioASRModelsConsented)
        let batchASRConsented = defaults.bool(forKey: Keys.fluidAudioBatchASRModelsConsented)
        fluidAudioBatchASRModelsConsented = batchASRConsented
        fluidAudioDiarizationModelsConsented = defaults.bool(forKey: Keys.fluidAudioDiarizationModelsConsented)
        fluidAudioVADModelsConsented = defaults.bool(forKey: Keys.fluidAudioVADModelsConsented)
        diagnosticReportsConsented = defaults.bool(forKey: AppSettingsKeys.diagnosticReportsConsented)
        // Transcription engine: prefer the stored value; otherwise migrate the
        // legacy `defaultMode` + on-device-multilingual pairing into the new
        // single explicit choice.
        let storedTranscriptionEngine = (defaults.string(forKey: Keys.transcriptionEngine))
            .flatMap(TranscriptionEngine.init(rawValue:))
        let resolvedTranscriptionEngine = storedTranscriptionEngine
            ?? Self.migratedTranscriptionEngine(
                mode: resolvedDefaultMode,
                language: resolvedDefaultLanguage,
                multilingualConsented: batchASRConsented
            )
        transcriptionEngine = resolvedTranscriptionEngine
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
        if let data = defaults.data(forKey: Keys.transcriptionModels),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            transcriptionModels = decoded
        } else {
            transcriptionModels = [:]
        }
        if let data = defaults.data(forKey: Keys.usageStats),
           let decoded = try? JSONDecoder().decode(UsageStats.self, from: data) {
            usageStats = decoded
        } else {
            usageStats = UsageStats()
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
    nonisolated static func migratedTranscriptionEngine(
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

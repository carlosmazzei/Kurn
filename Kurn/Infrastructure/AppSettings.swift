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
        static let alwaysUseBuiltInMic = "settings.alwaysUseBuiltInMic"
        static let summaryModels = "settings.summaryModels"
        static let summaryTemplates = "settings.summaryTemplates"
        static let lastSummaryTemplate = "settings.lastSummaryTemplate"
        static let liveTranscriptionEnabled = "settings.liveTranscriptionEnabled"
        static let diarizationEngine = "settings.diarizationEngine"
        static let fluidAudioSpeakerCount = "settings.fluidAudioSpeakerCount"
        /// Superseded by `fluidAudioSpeakerCount`; read once at init to migrate.
        static let legacyFluidAudioMinSpeakers = "settings.fluidAudioMinSpeakers"
        static let diarizationPreprocessingEnabled = "settings.diarizationPreprocessingEnabled"
        static let diarizationDereverbEnabled = "settings.diarizationDereverbEnabled"
        static let playbackEnhancementEnabled = "settings.playbackEnhancementEnabled"
        static let transcriptionEngine = "settings.transcriptionEngine"
        static let preprocessingEngine = "settings.preprocessingEngine"
        static let vadEngine = "settings.vadEngine"
        static let languageDetectionEngine = "settings.languageDetectionEngine"
        static let fluidAudioASRModelsConsented = "settings.fluidAudioASRModelsConsented"
        static let fluidAudioBatchASRModelsConsented = "settings.fluidAudioBatchASRModelsConsented"
        static let fluidAudioDiarizationModelsConsented = "settings.fluidAudioDiarizationModelsConsented"
        static let fluidAudioVADModelsConsented = "settings.fluidAudioVADModelsConsented"
        static let whisperCppModel = "settings.whisperCppModel"
        static let whisperCppModelsConsented = "settings.whisperCppModelsConsented"
        static let logLevel = "settings.logLevel"
        static let requireAuthForRecordings = "settings.requireAuthForRecordings"
        static let hideLiveActivityMeetingTitle = "settings.hideLiveActivityMeetingTitle"
        static let meetingsSortOrder = "settings.meetingsSortOrder"
        static let autoTaggingEnabled = "settings.autoTaggingEnabled"
        static let usageStats = "settings.usageStats"
        static let semanticSearchEnabled = "settings.semanticSearchEnabled"
        static let wikiEnabled = "settings.wikiEnabled"
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

    /// When on, recordings always use the iPhone's built-in microphone, even
    /// if an external (e.g. Bluetooth) input is connected, and the recorder
    /// never asks which microphone to use. Off by default, so a connected
    /// accessory is offered as a choice when more than one input is available.
    var alwaysUseBuiltInMic: Bool {
        didSet { defaults.set(alwaysUseBuiltInMic, forKey: Keys.alwaysUseBuiltInMic) }
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

    /// Whether on-device semantic indexing, search, and meeting chat retrieval
    /// are active. On by default: embeddings run fully on-device (Apple's
    /// `NLContextualEmbedding`, no third-party model), and the vectors persist in
    /// the encrypted SwiftData store. Turning it off makes list search fall back
    /// to substring matching and disables the chat retrieval index; it does not
    /// delete existing chunks (use "Clear index" in Settings for that).
    var semanticSearchEnabled: Bool {
        didSet { defaults.set(semanticSearchEnabled, forKey: Keys.semanticSearchEnabled) }
    }

    /// Whether the LLM-generated per-meeting "wiki" is built and used by the
    /// library-wide chat's synthesis path. Unlike `semanticSearchEnabled`, this
    /// is **off by default**: generating articles makes cloud LLM calls (one per
    /// meeting), so it must be an explicit opt-in. When on, articles are generated
    /// after each transcription and backfilled in small batches, and cross-meeting
    /// "synthesis" questions are answered over the articles instead of raw
    /// passages.
    var wikiEnabled: Bool {
        didSet { defaults.set(wikiEnabled, forKey: Keys.wikiEnabled) }
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

    /// Exact number of speakers to pin on the FluidAudio (neural) diarizer.
    /// `0` means "let it decide". On far-field/single-mic audio the neural
    /// pipeline's VBx step collapses every cluster into one speaker; pinning a
    /// count makes FluidAudio re-cluster the raw speaker embeddings with KMeans
    /// into exactly that many speakers instead. Ignored by the heuristic
    /// engine, which auto-detects from pitch/timbre.
    ///
    /// This replaced a *minimum* speaker setting, which could not work: the
    /// library only applies a speaker-count constraint when the count it
    /// detected falls outside the bounds, and the count it compares is the
    /// pre-clustering estimate (tens, on any real meeting), so a floor of 2 or 3
    /// was always already satisfied. See `FluidAudioDiarizer.tunedConfig`.
    var fluidAudioSpeakerCount: Int {
        didSet { defaults.set(fluidAudioSpeakerCount, forKey: Keys.fluidAudioSpeakerCount) }
    }

    /// When on, the diarization stage runs a dedicated lighter cleanup
    /// (`DiarizationPreprocessor`) on the original recording and feeds the
    /// resulting WAV to both diarizer engines. When off, diarization uses the
    /// original recording directly. It never reuses the ASR-tuned `.m4a`
    /// produced by `AudioPreprocessor`.
    var diarizationPreprocessingEnabled: Bool {
        didSet { defaults.set(diarizationPreprocessingEnabled, forKey: Keys.diarizationPreprocessingEnabled) }
    }

    /// When on, the diarization cleanup additionally runs WPE dereverberation
    /// before its noise reduction. Experimental and off by default: WPE is the
    /// standard far-field front end in the DIHARD/CHiME evaluations and is linear
    /// (so it cannot distort the timbre speaker embeddings read), but its benefit
    /// on this app's own material has not been measured, and it costs real
    /// processing time on a long recording.
    var diarizationDereverbEnabled: Bool {
        didSet { defaults.set(diarizationDereverbEnabled, forKey: Keys.diarizationDereverbEnabled) }
    }

    /// When on, playback prefers an enhanced copy of each recording — equalized,
    /// level-controlled and loudness-normalized — generated on first use. Off by
    /// default: it changes what the user hears relative to what was recorded, and
    /// it costs a second audio file per recording.
    var playbackEnhancementEnabled: Bool {
        didSet { defaults.set(playbackEnhancementEnabled, forKey: Keys.playbackEnhancementEnabled) }
    }

    /// Engine that turns audio into text. Replaces the legacy `defaultMode` +
    /// on-device-multilingual pairing; `init` migrates the old keys into this.
    var transcriptionEngine: TranscriptionEngine {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// GGML weight file the on-device Whisper (whisper.cpp) engine runs. Only
    /// meaningful when `transcriptionEngine` is `.whisperCpp`.
    var whisperCppModel: WhisperCppModel {
        didSet { defaults.set(whisperCppModel.rawValue, forKey: Keys.whisperCppModel) }
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
            fluidAudioSpeakerCount: fluidAudioSpeakerCount,
            diarizationPreprocessingEnabled: diarizationPreprocessingEnabled,
            diarizationDereverbEnabled: diarizationDereverbEnabled,
            whisperCppModel: whisperCppModel
        )
    }

    /// Whether the selected pipeline relies on the FluidAudio on-device ASR model
    /// (as the Parakeet transcriber or the auto-language detector) *and* the user
    /// has consented to downloading it. Gates foreground pre-warming so the model
    /// is only loaded for users who will actually use it, and never downloaded
    /// without consent. See `FluidAudioModelStore.prewarm()`.
    var usesFluidAudioModel: Bool {
        let needsOnDeviceASR = transcriptionEngine.requiredModelSet(whisperCppModel: whisperCppModel) == .onDeviceASR
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

    /// Whether the user has consented to downloading whisper.cpp's GGML weights
    /// for the on-device Whisper engine. Which variant is downloaded is a
    /// separate choice (`whisperCppModel`).
    var whisperCppModelsConsented: Bool {
        didSet { defaults.set(whisperCppModelsConsented, forKey: Keys.whisperCppModelsConsented) }
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
        // An empty stored list is treated as absent: it can only come from a
        // corrupt write, and shipping the app with no providers at all is worse
        // than re-seeding the built-ins.
        let loadedProviders = defaults.decoded([AIProvider].self, forKey: Keys.providers)
            .flatMap { $0.isEmpty ? nil : $0 }
            .map(Self.mergedProviders) ?? AIProvider.defaultProviders
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
        let resolvedDefaultMode = defaults.enumValue(forKey: Keys.defaultMode, default: TranscriptionMode.onDevice)
        defaultMode = resolvedDefaultMode
        let resolvedDefaultLanguage = defaults.enumValue(forKey: Keys.defaultLanguage, default: MeetingLanguage.autoDetect)
        defaultLanguage = resolvedDefaultLanguage
        micPickup = defaults.enumValue(forKey: Keys.micPickup, default: .wholeRoom)
        // `.standard` (48 kbps mono at the recorder's fixed 24kHz) is transparent
        // for speech, so it is the default rather than `.high`. Users who already
        // picked a tier keep it — they still gain from the fixed sample rate.
        audioQuality = defaults.enumValue(forKey: Keys.audioQuality, default: .standard)
        alwaysUseBuiltInMic = defaults.bool(forKey: Keys.alwaysUseBuiltInMic)
        meetingsSortOrder = defaults.enumValue(forKey: Keys.meetingsSortOrder, default: .dateNewest)
        autoTaggingEnabled = defaults.bool(forKey: Keys.autoTaggingEnabled, default: false)
        liveTranscriptionEnabled = defaults.bool(forKey: Keys.liveTranscriptionEnabled)
        semanticSearchEnabled = defaults.bool(forKey: Keys.semanticSearchEnabled, default: true)
        // Off by default: wiki generation makes paid cloud LLM calls, so it is an
        // explicit opt-in.
        wikiEnabled = defaults.bool(forKey: Keys.wikiEnabled, default: false)
        // Screenshot automation (fastlane `snapshot`) always forces this off so
        // the recordings lock screen never blocks an unattended UI test run.
        #if DEBUG
        let screenshotRun = ProcessInfo.processInfo.arguments.contains("UI-Testing-Screenshots")
        #else
        let screenshotRun = false
        #endif
        requireAuthForRecordings = screenshotRun
            ? false
            : defaults.bool(forKey: Keys.requireAuthForRecordings, default: true)
        hideLiveActivityMeetingTitle = defaults.bool(forKey: Keys.hideLiveActivityMeetingTitle, default: true)
        diarizationEngine = defaults.enumValue(forKey: Keys.diarizationEngine, default: .heuristic)
        // Migration: the old key held a *minimum* speaker count that never
        // engaged (see `fluidAudioSpeakerCount`). Carry the number over as the
        // pinned count — it is the count the user believed they were asking for.
        if let pinned = defaults.object(forKey: Keys.fluidAudioSpeakerCount) as? Int {
            fluidAudioSpeakerCount = pinned
        } else {
            fluidAudioSpeakerCount = defaults.integer(forKey: Keys.legacyFluidAudioMinSpeakers)
        }
        diarizationPreprocessingEnabled = defaults.bool(forKey: Keys.diarizationPreprocessingEnabled, default: true)
        diarizationDereverbEnabled = defaults.bool(forKey: Keys.diarizationDereverbEnabled)
        playbackEnhancementEnabled = defaults.bool(forKey: Keys.playbackEnhancementEnabled)
        fluidAudioASRModelsConsented = defaults.bool(forKey: Keys.fluidAudioASRModelsConsented)
        let batchASRConsented = defaults.bool(forKey: Keys.fluidAudioBatchASRModelsConsented)
        fluidAudioBatchASRModelsConsented = batchASRConsented
        fluidAudioDiarizationModelsConsented = defaults.bool(forKey: Keys.fluidAudioDiarizationModelsConsented)
        fluidAudioVADModelsConsented = defaults.bool(forKey: Keys.fluidAudioVADModelsConsented)
        whisperCppModelsConsented = defaults.bool(forKey: Keys.whisperCppModelsConsented)
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
        preprocessingEngine = defaults.enumValue(forKey: Keys.preprocessingEngine, default: .standardDSP)
        vadEngine = defaults.enumValue(forKey: Keys.vadEngine, default: .energyThreshold)
        languageDetectionEngine = defaults.enumValue(forKey: Keys.languageDetectionEngine, default: .byTranscriber)
        whisperCppModel = defaults.enumValue(forKey: Keys.whisperCppModel, default: WhisperCppModel.default)
        // Fall back to the environment-derived default (set on `AppLog` at
        // launch) when the user hasn't chosen a level yet.
        let resolvedLogLevel = defaults.enumValue(forKey: Keys.logLevel, default: AppLog.minimumLevel)
        logLevel = resolvedLogLevel
        AppLog.minimumLevel = resolvedLogLevel
        summaryModels = defaults.decoded([String: String].self, forKey: Keys.summaryModels) ?? [:]
        transcriptionModels = defaults.decoded([String: String].self, forKey: Keys.transcriptionModels) ?? [:]
        usageStats = defaults.decoded(UsageStats.self, forKey: Keys.usageStats) ?? UsageStats()
        // As with `providers`, an empty stored list re-seeds the built-in presets.
        let loadedTemplates = defaults.decoded([SummaryTemplate].self, forKey: Keys.summaryTemplates)
            .flatMap { $0.isEmpty ? nil : $0 }
            .map(Self.mergedTemplates) ?? SummaryTemplate.defaultTemplates
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

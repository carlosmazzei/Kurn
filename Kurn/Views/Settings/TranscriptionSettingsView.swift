//
//  TranscriptionSettingsView.swift
//  Kurn
//
//  The recognition pipeline: which engine turns audio into text, and the stages
//  around it (cleanup, voice-activity detection, language detection, speaker
//  diarization). Split into "engine and language" and "advanced pipeline" so the
//  choice most people make isn't buried under six stage pickers.
//

import KurnCore
import SwiftUI

enum TranscriptionSettingsMode: String, CaseIterable, Identifiable {
    case simple
    case advanced

    var id: String { rawValue }

    var title: String {
        NSLocalizedString("settings.mode.\(rawValue)", comment: "Transcription settings mode")
    }
}

struct TranscriptionSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads
    @State private var cloudConsent = CloudTranscriptionConsentController()
    /// Simple shows the four named presets; Advanced shows every stage picker.
    /// Defaults to Simple only when the current pipeline matches a preset —
    /// anything hand-tuned opens Advanced so it isn't silently rewritten.
    @State private var mode: TranscriptionSettingsMode = .advanced
    /// A preset mid-application, waiting on consent dialogs: re-driven from
    /// `advancePending` as the settings it gates actually change.
    @State private var pendingPreset: TranscriptionPreset?
    /// Set when a cloud preset is tapped while its provider has no key —
    /// mirrors how the Whisper engine row greys out instead of switching.
    @State private var missingKeyProvider: AIProvider?

    /// Re-derives after any key change, wherever this screen was opened from:
    /// the list reads through the observable `settings.credentials`.
    private var transcriptionProviders: [AIProvider] {
        settings.configuredTranscriptionProviders
    }

    private var hasAnyTranscriptionProvider: Bool { !transcriptionProviders.isEmpty }

    /// The correction stage reuses the summary provider, so its toggle reacts
    /// to the same key changes.
    private var hasSummaryProviderKey: Bool {
        settings.credentials.isUsable(settings.aiProvider)
    }

    /// The reason the correction toggle is disabled, when it is — naming the
    /// on-device unavailability reason rather than suggesting an API key.
    private var correctionUnavailableFooter: String {
        if settings.aiProvider.kind == .appleOnDevice, let reason = OnDeviceModelAvailability.unavailableReason {
            return reason
        }
        return NSLocalizedString("settings.correction_needs_key", comment: "AI transcription correction needs an API key")
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(
                NSLocalizedString("settings.mode", comment: "Settings mode"),
                selection: $mode
            ) {
                ForEach(TranscriptionSettingsMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("settings.transcription.mode")

            if mode == .simple {
                TranscriptionPresetsView(
                    current: TranscriptionPreset.current(settings: settings)
                ) { preset in
                    apply(preset)
                }
            } else {
                Form {
                    recognitionSection
                    whoSpokeSection
                    pipelineSection
                    correctionSection
                    networkTransferSection
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.transcription", comment: "Transcription"))
        .modelDownloadAlerts(downloads, settings: settings)
        .presetMissingKeyAlert(provider: $missingKeyProvider)
        .onAppear {
            if TranscriptionPreset.current(settings: settings) != nil { mode = .simple }
        }
        .cloudUploadConsentDialog(
            consent: cloudConsent,
            settings: settings,
            providers: transcriptionProviders,
            downloads: downloads
        )
        .onAppear { cloudConsent.presentIfNeeded(settings: settings) }
        .onChange(of: settings.transcriptionProviderID) { _, _ in advancePending() }
        .onChange(of: settings.transcriptionEngine) { _, _ in advancePending() }
        .onChange(of: settings.fluidAudioASRModel) { _, _ in advancePending() }
        .onChange(of: settings.fluidAudioDiarizationModel) { _, _ in advancePending() }
        .onChange(of: settings.diarizationEngine) { _, _ in advancePending() }
        .onChange(of: settings.vadEngine) { _, _ in advancePending() }
        // The gated fields change while `isDownloading` is still true (the
        // download applies them in its success block before clearing), so
        // the chain would stall without a resume once the download ends.
        .onChange(of: downloads.isDownloading) { _, downloading in
            if !downloading { advancePending() }
        }
        .onChange(of: cloudConsent.isPresented) { was, presented in
            // why: a dismissed upload-consent dialog whose field never
            // landed means the user declined — retire the preset so an
            // unrelated Advanced edit can't resume it later.
            if was && !presented { clearPendingIfCloudStepUnmet() }
        }
        .onChange(of: anyDownloadPromptPresented) { was, presented in
            // why: same for a download-consent prompt dismissed without a
            // download starting — the pending preset must not stay live.
            if was && !presented && !downloads.isDownloading { clearPendingIfDownloadStepUnmet() }
        }
        .onChange(of: mode) { _, new in
            // why: switching to Advanced is an explicit "hand-tune" gesture;
            // a preset still waiting on consent must not keep firing there.
            if new == .advanced { pendingPreset = nil }
        }
    }

    /// Whether any of `ModelDownloadController`'s consent prompts is shown —
    /// the preset chain can trigger any of them depending on which gated
    /// step it reaches.
    private var anyDownloadPromptPresented: Bool {
        downloads.showingFluidAudioModelConsent || downloads.showingBatchASRConsent
            || downloads.showingDiarizationConsent || downloads.showingSherpaOnnxConsent
            || downloads.showingVADConsent || downloads.showingWhisperCppConsent
            || downloads.showingWhisperCppModelChoice
    }

    // MARK: - Recognition

    @ViewBuilder
    private var recognitionSection: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { settings.defaultLanguage },
                    set: { settings.defaultLanguage = $0 }
                )
            ) {
                ForEach(MeetingLanguage.allCases) { lang in
                    LanguagePickerRow(
                        language: lang,
                        engine: settings.transcriptionEngine,
                        fluidAudioASRModel: settings.fluidAudioASRModel
                    ).tag(lang)
                }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.default_language", comment: "Default language"),
                    detail: NSLocalizedString("settings.language_support_footer", comment: "Explains the unsupported-language warning icon")
                )
            }

            Picker(
                NSLocalizedString("pipeline.transcription_engine", comment: "Transcription engine"),
                selection: Binding(
                    get: { settings.transcriptionEngine },
                    set: {
                        cloudConsent.selectEngine(
                            $0,
                            settings: settings,
                            providers: transcriptionProviders,
                            downloads: downloads
                        )
                    }
                )
            ) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName)
                        .tag(engine)
                        .disabled(engine == .whisperAPI && !hasAnyTranscriptionProvider)
                }
            }
            .accessibilityIdentifier("settings.transcription.engine")
            .disabled(downloads.isDownloading)

            // Why the Whisper option is greyed out, right under the picker
            // that greys it out.
            if !hasAnyTranscriptionProvider {
                Text(NSLocalizedString(
                    "settings.whisper_provider_key_missing_footer",
                    comment: "Whisper transcription provider key dependency"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            // Cloud transcription provider + model, chosen independently of the
            // summary provider. Only shown for the Whisper engine.
            if settings.transcriptionEngine == .whisperAPI {
                Picker(
                    NSLocalizedString("settings.transcription_provider", comment: "Transcription provider"),
                    selection: Binding(
                        get: { settings.transcriptionProviderID },
                        set: {
                            cloudConsent.selectProvider(
                                $0,
                                settings: settings,
                                providers: transcriptionProviders
                            )
                        }
                    )
                ) {
                    ForEach(transcriptionProviders) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                TranscriptionModelPicker(
                    settings: settings,
                    provider: settings.transcriptionProvider
                )
                Text(NSLocalizedString(
                    "settings.whisper_provider_key_footer",
                    comment: "Whisper transcription provider key dependency"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            // Which GGML weight file the on-device Whisper engine loads. Each
            // variant is a separate download, so switching can trigger one.
            if settings.transcriptionEngine == .whisperCpp {
                Picker(
                    NSLocalizedString("settings.whisper_cpp.model", comment: "Whisper model size"),
                    selection: Binding(
                        get: { settings.whisperCppModel },
                        set: { downloads.selectWhisperCppModel($0, settings: settings) }
                    )
                ) {
                    ForEach(WhisperCppModel.allCases) { model in
                        Text(verbatim: "\(model.displayName) · \(Self.sizeLabel(model))").tag(model)
                    }
                }
                .disabled(downloads.isDownloading)
                Text(NSLocalizedString("settings.whisper_cpp.model_footer", comment: "Whisper model size help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if settings.transcriptionEngine == .fluidAudioParakeet {
                FluidAudioASRSettingsControls()
            }

            if FluidAudioModelPresentation.downloadSection(for: downloads.downloadingModel) == .transcription {
                ModelDownloadProgressRow(progress: downloads.downloadProgress, onCancel: downloads.cancelDownload)
            }
        } header: {
            Text(NSLocalizedString("settings.recognition", comment: "Recognition"))
        }
    }

    /// Approximate download size, so the cost of a variant is visible before
    /// picking it.
    private static func sizeLabel(_ model: WhisperCppModel) -> String {
        ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file)
    }

    private var networkTransferSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.network.allow_expensive", comment: "Allow cellular transfers"),
                isOn: Binding(
                    get: { settings.allowsExpensiveNetworkTransfers },
                    set: { settings.allowsExpensiveNetworkTransfers = $0 }
                )
            )
            Toggle(
                NSLocalizedString("settings.network.allow_constrained", comment: "Allow Low Data Mode transfers"),
                isOn: Binding(
                    get: { settings.allowsConstrainedNetworkTransfers },
                    set: { settings.allowsConstrainedNetworkTransfers = $0 }
                )
            )
        } header: {
            Text(NSLocalizedString("settings.network.large_transfers", comment: "Large transfers"))
        } footer: {
            Text(NSLocalizedString("settings.network.large_transfers_footer", comment: "Large transfer network policy"))
        }
    }

    // MARK: - Advanced stages

    @ViewBuilder
    private var pipelineSection: some View {
        Section {
            // Audio cleanup/normalization.
            Toggle(
                isOn: Binding(
                    get: { settings.preprocessingEngine == .standardDSP },
                    set: { enabled in
                        settings.preprocessingEngine = enabled ? .standardDSP : .none
                    }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("pipeline.preprocessing", comment: "Audio cleanup"),
                    detail: NSLocalizedString("pipeline.preprocessing_footer", comment: "Explains audio cleanup")
                )
            }

            // Voice-activity detection.
            Picker(
                selection: Binding(
                    get: { settings.vadEngine },
                    set: { downloads.selectVADEngine($0, settings: settings) }
                )
            ) {
                ForEach(VADEngine.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("pipeline.vad", comment: "Voice activity detection"),
                    detail: NSLocalizedString("pipeline.vad_footer", comment: "Explains voice activity detection")
                )
            }
            .disabled(downloads.isDownloading)

            // Language detection.
            Picker(
                selection: Binding(
                    get: { settings.languageDetectionEngine },
                    set: { downloads.selectLanguageDetectionEngine($0, settings: settings) }
                )
            ) {
                ForEach(LanguageDetectionEngine.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("pipeline.language_detection", comment: "Language detection"),
                    detail: NSLocalizedString("pipeline.language_detection_footer", comment: "Explains language detection")
                )
            }
            .disabled(downloads.isDownloading)

        } header: {
            Text(NSLocalizedString("settings.pipeline", comment: "Pipeline"))
        }
    }

    // MARK: - Who spoke

    @ViewBuilder
    private var whoSpokeSection: some View {
        Section {
            // Speaker diarization.
            Picker(
                selection: Binding(
                    get: { settings.diarizationEngine },
                    set: { downloads.selectDiarizationEngine($0, settings: settings) }
                )
            ) {
                ForEach(DiarizationEngine.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.diarization_engine", comment: "Diarization engine"),
                    detail: NSLocalizedString("settings.diarization_engine_footer", comment: "Explains diarization engine choice")
                )
            }
            .disabled(downloads.isDownloading)

            if settings.diarizationEngine == .fluidAudio {
                FluidAudioDiarizationSettingsControls()
            }

            // Dedicated diarization cleanup. This controls only the diarization
            // input; the ASR cleanup toggle controls only the transcription
            // path.
            Toggle(
                NSLocalizedString("settings.diarization_preprocessing", comment: "Diarization audio cleanup"),
                isOn: Binding(
                    get: { settings.diarizationPreprocessingEnabled },
                    set: { settings.diarizationPreprocessingEnabled = $0 }
                )
            )
            .disabled(downloads.isDownloading)

            // Pinned speaker count for the neural (FluidAudio) engine. On
            // far-field/single-mic audio its clustering step collapses everyone
            // into one speaker; pinning the count re-clusters the raw speaker
            // embeddings into exactly that many. Left at Auto, the engine
            // decides and the app re-clusters on its own if it collapsed.
            // Hidden for the heuristic engine, which auto-detects.
            if settings.diarizationEngine == .fluidAudio && settings.fluidAudioDiarizationModel.supportsPinnedSpeakerCount {
                Stepper(
                    value: Binding(
                        get: { settings.fluidAudioSpeakerCount },
                        set: { settings.fluidAudioSpeakerCount = $0 }
                    ),
                    in: 0...10
                ) {
                    HStack {
                        Text(NSLocalizedString("settings.diarization_speaker_count", comment: "Number of speakers"))
                        Spacer()
                        Text(
                            settings.fluidAudioSpeakerCount == 0
                                ? NSLocalizedString("settings.diarization_speaker_count_auto", comment: "Auto")
                                : "\(settings.fluidAudioSpeakerCount)"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(downloads.isDownloading)
                Text(NSLocalizedString("settings.diarization_speaker_count_footer", comment: "Speaker count help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if FluidAudioModelPresentation.downloadSection(for: downloads.downloadingModel) == .diarization {
                ModelDownloadProgressRow(progress: downloads.downloadProgress, onCancel: downloads.cancelDownload)
            }
        } header: {
            Text(NSLocalizedString("settings.who_spoke", comment: "Who spoke"))
        }
    }

    // MARK: - AI correction

    @ViewBuilder
    private var correctionSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.correction", comment: "AI transcription correction toggle"),
                isOn: Binding(
                    get: { settings.correctionEnabled && hasSummaryProviderKey },
                    set: { settings.correctionEnabled = $0 }
                )
            )
            .disabled(!hasSummaryProviderKey)
        } header: {
            Text(NSLocalizedString("settings.correction_title", comment: "AI transcription correction section title"))
        } footer: {
            Text(hasSummaryProviderKey
                ? NSLocalizedString("settings.correction_footer", comment: "AI transcription correction footer")
                : correctionUnavailableFooter)
        }
    }
}

private extension TranscriptionSettingsView {
    // MARK: - Preset application

    /// Starts a preset. Every step the preset needs is routed through the
    /// existing consent paths, so nothing lands until the user confirms:
    /// a cloud provider/engine goes through `CloudTranscriptionConsentController`
    /// (the audio-upload dialog), on-device models through
    /// `ModelDownloadController`'s download consent, and FluidAudio/VAD
    /// engines through their deferred-download pending state.
    private func apply(_ preset: TranscriptionPreset) {
        let choice = preset.choice(for: settings.defaultLanguage)
        if let providerID = choice.cloudProviderID,
           !transcriptionProviders.contains(where: { $0.id == providerID }) {
            missingKeyProvider = settings.providers.first(where: { $0.id == providerID })
            return
        }
        pendingPreset = preset
        advancePending()
    }

    /// Applies the preset one gated field at a time, in an order that keeps
    /// each consent dialog about one thing: provider first (audio-upload
    /// consent), then the FluidAudio models (download consent), then the
    /// engines — the FluidAudio engine interception reuses the already-set
    /// model — then diarization and VAD. When every gated field matches, the
    /// ungated leftovers (cloud model, preprocessing) land and the preset is
    /// done. If a dialog was cancelled, the field never changed and the
    /// preset stays pending-but-inert until the user picks again.
    private func advancePending() {
        guard let preset = pendingPreset, !downloads.isDownloading else { return }
        let choice = preset.choice(for: settings.defaultLanguage)
        switch TranscriptionPreset.nextUnmetStep(
            target: choice,
            current: currentPipelineChoice()
        ) {
        case .cloudProvider:
            if let providerID = choice.cloudProviderID {
                cloudConsent.selectProvider(providerID, settings: settings, providers: transcriptionProviders)
            }
        case .asrModel:
            if let model = choice.asrModel {
                downloads.selectFluidAudioASRModel(model, settings: settings)
            }
        case .diarizationModel:
            if let model = choice.diarizationModel {
                downloads.selectFluidAudioDiarizationModel(model, settings: settings)
            }
        case .engine:
            if choice.engine == .whisperAPI {
                cloudConsent.selectEngine(
                    choice.engine,
                    settings: settings,
                    providers: transcriptionProviders,
                    downloads: downloads
                )
            } else {
                downloads.selectTranscriptionEngine(
                    choice.engine,
                    settings: settings,
                    transcriptionProviders: transcriptionProviders
                )
            }
        case .diarization:
            downloads.selectDiarizationEngine(choice.diarization, settings: settings)
        case .vad:
            downloads.selectVADEngine(choice.vad, settings: settings)
        case nil:
            if let providerID = choice.cloudProviderID,
               let model = choice.cloudModel,
               let provider = settings.providers.first(where: { $0.id == providerID }) {
                settings.setTranscriptionModel(model, for: provider)
            }
            settings.preprocessingEngine = choice.preprocessing
            pendingPreset = nil
        }
    }

    /// The pipeline as configured, but with the raw stored transcription
    /// provider — `TranscriptionPipelineChoice(settings:)` masks it unless the
    /// engine is already remote, which would keep a cloud preset stuck on the
    /// provider step before the engine ever switches.
    private func currentPipelineChoice() -> TranscriptionPipelineChoice {
        var choice = TranscriptionPipelineChoice(settings: settings)
        choice.cloudProviderID = settings.transcriptionProviderID
        return choice
    }

    /// A dismissed audio-upload dialog means the pending cloud step was
    /// declined when its field still differs from the preset's target.
    private func clearPendingIfCloudStepUnmet() {
        guard let preset = pendingPreset else { return }
        let choice = preset.choice(for: settings.defaultLanguage)
        let step = TranscriptionPreset.nextUnmetStep(
            target: choice,
            current: currentPipelineChoice()
        )
        if step == .cloudProvider || (step == .engine && choice.engine == .whisperAPI) {
            pendingPreset = nil
        }
    }

    /// A dismissed download-consent prompt means the pending step was
    /// declined when it is the still-unmet one (every download-gated step —
    /// models, on-device engines — maps to one of those prompts).
    private func clearPendingIfDownloadStepUnmet() {
        guard let preset = pendingPreset else { return }
        let choice = preset.choice(for: settings.defaultLanguage)
        switch TranscriptionPreset.nextUnmetStep(
            target: choice,
            current: currentPipelineChoice()
        ) {
        case .asrModel, .diarizationModel, .diarization, .vad:
            pendingPreset = nil
        case .engine where choice.engine != .whisperAPI:
            pendingPreset = nil
        default:
            break
        }
    }

}

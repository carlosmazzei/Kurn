//
//  SettingsView.swift
//  Kurn
//
//  App configuration: AI providers + API keys (stored in Keychain), default
//  transcription mode/language, summary provider + model, recording mic pickup +
//  audio quality, storage usage, and destructive data reset.
//

import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var storageText = "—"
    @State private var showingDeleteConfirm = false
    /// Bytes used on disk per downloaded FluidAudio model group, refreshed when
    /// the screen appears and after any download/deletion.
    @State private var modelSizes: [ModelStore.ModelGroup: Int64] = [:]
    /// Model group awaiting a delete confirmation, if any.
    @State private var pendingModelDeletion: ModelStore.ModelGroup?
    @State private var showingAddProvider = false
    @State private var showingAddTemplate = false
    /// Bumped after editing a key so the provider rows re-read keychain status.
    @State private var keyRevision = 0

    @State private var showingASRConsent = false
    @State private var showingBatchASRConsent = false
    @State private var showingDiarizationConsent = false
    @State private var pendingDiarizationEngine: DiarizationEngine?
    /// Engine choices awaiting a successful on-device-ASR model download before
    /// they're applied (both the transcription and language-detection pickers
    /// can require that model).
    @State private var pendingTranscriptionEngine: TranscriptionEngine?
    @State private var pendingLanguageDetectionEngine: LanguageDetectionEngine?
    /// Which FluidAudio model set is currently downloading (`nil` when idle), so
    /// the toggle/picker can't be re-triggered mid-download and the matching
    /// section can surface a progress indicator.
    @State private var downloadingModel: ModelSet?
    /// Surfaced only if a consented download actually fails — the consent
    /// flags themselves are set after success, so a failure leaves the
    /// feature off and the consent alert available to retry.
    @State private var modelDownloadError: AppError?

    var body: some View {
        @Bindable var settings = settings

        Form {
            // MARK: AI providers
            Section(NSLocalizedString("settings.providers", comment: "AI Providers")) {
                ForEach(settings.providers) { provider in
                    NavigationLink {
                        ProviderEditor(
                            provider: provider,
                            onSave: { updated in
                                settings.updateProvider(updated)
                                keyRevision += 1
                            },
                            onDelete: {
                                settings.removeProvider(provider)
                                keyRevision += 1
                            },
                            onChange: { keyRevision += 1 }
                        )
                    } label: {
                        ProviderRow(provider: provider, revision: keyRevision)
                    }
                }
                Button {
                    showingAddProvider = true
                } label: {
                    Label(NSLocalizedString("settings.add_provider", comment: "Add Provider"), systemImage: "plus")
                }
            }

            // MARK: Transcription
            transcriptionSection(settings: settings)

            // MARK: Summary
            Section(NSLocalizedString("settings.summary", comment: "Summary")) {
                if configuredProviders.isEmpty {
                    Text(NSLocalizedString("settings.no_configured_providers", comment: "No configured providers"))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Picker(
                        NSLocalizedString("settings.provider", comment: "Provider"),
                        selection: $settings.aiProviderID
                    ) {
                        ForEach(configuredProviders) { Text($0.displayName).tag($0.id) }
                    }
                    SummaryModelPicker(settings: settings, provider: settings.aiProvider, revision: keyRevision)
                }
            }

            // MARK: Summary templates
            Section {
                ForEach(settings.summaryTemplates) { template in
                    NavigationLink {
                        TemplateEditor(
                            template: template,
                            onSave: { settings.updateTemplate($0) },
                            onDelete: { settings.removeTemplate(template) }
                        )
                    } label: {
                        TemplateRow(template: template)
                    }
                }
                Button {
                    showingAddTemplate = true
                } label: {
                    Label(NSLocalizedString("settings.add_template", comment: "Add Template"), systemImage: "plus")
                }
            } header: {
                Text(NSLocalizedString("settings.templates", comment: "Summary Templates"))
            } footer: {
                Text(NSLocalizedString("settings.templates_footer", comment: "Templates footer"))
            }

            // MARK: Recording
            recordingSection(settings: settings)

            // MARK: Diagnostics
            diagnosticsSection(settings: settings)

            // MARK: Storage
            Section(NSLocalizedString("settings.storage", comment: "Storage")) {
                LabeledContent(
                    NSLocalizedString("settings.audio_usage", comment: "Audio usage"),
                    value: storageText
                )
            }

            // MARK: Downloaded models
            modelsSection

            Section {
                Button(role: .destructive) { showingDeleteConfirm = true } label: {
                    Text(NSLocalizedString("settings.delete_all", comment: "Delete All Data"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.title", comment: "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddProvider) {
            NavigationStack {
                AddProviderView { provider, key in
                    settings.addProvider(provider)
                    if !key.isEmpty {
                        KeychainManager.shared.set(key, for: provider.keychainAccount)
                    }
                    keyRevision += 1
                    showingAddProvider = false
                }
            }
        }
        .sheet(isPresented: $showingAddTemplate) {
            NavigationStack {
                AddTemplateView { template in
                    settings.addTemplate(template)
                    showingAddTemplate = false
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
        .onAppear {
            refreshStorage()
            refreshModelSizes()
            ensureSelectedProviderIsConfigured()
            ensureWhisperSelectionIsAllowed()
        }
        .alert(
            NSLocalizedString("settings.models.delete_confirm", comment: "Confirm delete model"),
            isPresented: Binding(
                get: { pendingModelDeletion != nil },
                set: { if !$0 { pendingModelDeletion = nil } }
            ),
            presenting: pendingModelDeletion
        ) { group in
            Button(NSLocalizedString("settings.models.delete", comment: "Delete model"), role: .destructive) {
                deleteModel(group)
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(NSLocalizedString("settings.models.delete_message", comment: "Re-download later"))
        }
        .onChange(of: keyRevision) { _, _ in
            ensureSelectedProviderIsConfigured()
            ensureWhisperSelectionIsAllowed()
        }
        .alert(
            NSLocalizedString("settings.delete_all.confirm", comment: "Confirm delete all"),
            isPresented: $showingDeleteConfirm
        ) {
            Button(NSLocalizedString("settings.delete_all", comment: "Delete All Data"), role: .destructive) {
                deleteAllData()
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.delete_all.message", comment: ""))
        }
        .modifier(ModelDownloadAlerts(
            showingASRConsent: $showingASRConsent,
            showingBatchASRConsent: $showingBatchASRConsent,
            showingDiarizationConsent: $showingDiarizationConsent,
            onConfirmASR: {
                downloadingModel = .liveTranscriptionASR
                Task {
                    // Keep a finite background window so the download isn't
                    // aborted the moment Settings leaves the foreground.
                    let background = BackgroundActivity()
                    background.begin(name: "ai.kurn.modelDownload")
                    defer { background.end() }
                    do {
                        try await ModelDownloadConsent.download(.liveTranscriptionASR)
                        settings.fluidAudioASRModelsConsented = true
                        settings.liveTranscriptionEnabled = true
                    } catch let appError as AppError {
                        modelDownloadError = appError
                    } catch {
                        modelDownloadError = .modelDownloadFailed(error.localizedDescription)
                    }
                    downloadingModel = nil
                    refreshModelSizes()
                }
            },
            onConfirmBatchASR: {
                downloadingModel = .onDeviceASR
                Task {
                    // Keep a finite background window so the download isn't
                    // aborted the moment Settings leaves the foreground.
                    let background = BackgroundActivity()
                    background.begin(name: "ai.kurn.modelDownload")
                    defer { background.end() }
                    do {
                        try await ModelDownloadConsent.download(.onDeviceASR)
                        settings.fluidAudioBatchASRModelsConsented = true
                        // Apply whichever picker requested the download.
                        if let engine = pendingTranscriptionEngine {
                            settings.transcriptionEngine = engine
                        }
                        if let engine = pendingLanguageDetectionEngine {
                            settings.languageDetectionEngine = engine
                        }
                    } catch let appError as AppError {
                        modelDownloadError = appError
                    } catch {
                        modelDownloadError = .modelDownloadFailed(error.localizedDescription)
                    }
                    pendingTranscriptionEngine = nil
                    pendingLanguageDetectionEngine = nil
                    downloadingModel = nil
                    refreshModelSizes()
                }
            },
            onCancelBatchASR: {
                pendingTranscriptionEngine = nil
                pendingLanguageDetectionEngine = nil
            },
            onConfirmDiarization: {
                guard let engine = pendingDiarizationEngine else { return }
                pendingDiarizationEngine = nil
                downloadingModel = .diarization
                Task {
                    // Keep a finite background window so the download isn't
                    // aborted the moment Settings leaves the foreground.
                    let background = BackgroundActivity()
                    background.begin(name: "ai.kurn.modelDownload")
                    defer { background.end() }
                    do {
                        try await ModelDownloadConsent.download(.diarization)
                        settings.fluidAudioDiarizationModelsConsented = true
                        settings.diarizationEngine = engine
                    } catch let appError as AppError {
                        modelDownloadError = appError
                    } catch {
                        modelDownloadError = .modelDownloadFailed(error.localizedDescription)
                    }
                    downloadingModel = nil
                    refreshModelSizes()
                }
            },
            onCancelDiarization: {
                pendingDiarizationEngine = nil
            }
        ))
        .alert(
            NSLocalizedString("common.error", comment: "Error"),
            isPresented: Binding(
                get: { modelDownloadError != nil },
                set: { if !$0 { modelDownloadError = nil } }
            ),
            presenting: modelDownloadError
        ) { _ in
            Button(NSLocalizedString("common.ok", comment: "OK"), role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
    }

    @ViewBuilder
    private func transcriptionSection(settings: AppSettings) -> some View {
        Section {
            // Transcription engine (the stage that turns audio into text).
            Picker(
                NSLocalizedString("pipeline.transcription_engine", comment: "Transcription engine"),
                selection: Binding(
                    get: { settings.transcriptionEngine },
                    set: { selectTranscriptionEngine($0, settings: settings) }
                )
            ) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName)
                        .tag(engine)
                        .disabled(engine == .whisperAPI && !hasOpenAIAPIKey)
                }
            }
            .disabled(downloadingModel != nil)

            Picker(
                NSLocalizedString("settings.default_language", comment: "Default language"),
                selection: Binding(
                    get: { settings.defaultLanguage },
                    set: { settings.defaultLanguage = $0 }
                )
            ) {
                ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
            }

            // Audio cleanup/normalization.
            Picker(
                NSLocalizedString("pipeline.preprocessing", comment: "Audio cleanup"),
                selection: Binding(
                    get: { settings.preprocessingEngine },
                    set: { settings.preprocessingEngine = $0 }
                )
            ) {
                ForEach(PreprocessingEngine.allCases) { Text($0.displayName).tag($0) }
            }

            // Voice-activity detection.
            Picker(
                NSLocalizedString("pipeline.vad", comment: "Voice activity detection"),
                selection: Binding(
                    get: { settings.vadEngine },
                    set: { settings.vadEngine = $0 }
                )
            ) {
                ForEach(VADEngine.allCases) { Text($0.displayName).tag($0) }
            }

            // Language detection.
            Picker(
                NSLocalizedString("pipeline.language_detection", comment: "Language detection"),
                selection: Binding(
                    get: { settings.languageDetectionEngine },
                    set: { selectLanguageDetectionEngine($0, settings: settings) }
                )
            ) {
                ForEach(LanguageDetectionEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloadingModel != nil)

            // Speaker diarization.
            Picker(
                NSLocalizedString("settings.diarization_engine", comment: "Diarization engine"),
                selection: Binding(
                    get: { settings.diarizationEngine },
                    set: { engine in
                        if engine == .fluidAudio && !settings.fluidAudioDiarizationModelsConsented {
                            pendingDiarizationEngine = engine
                            showingDiarizationConsent = true
                        } else {
                            settings.diarizationEngine = engine
                        }
                    }
                )
            ) {
                ForEach(DiarizationEngine.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(downloadingModel != nil)

            if downloadingModel == .onDeviceASR || downloadingModel == .diarization {
                modelDownloadProgressRow
            }
        } header: {
            Text(NSLocalizedString("settings.recognition_pipeline", comment: "Recognition pipeline"))
        } footer: {
            Text(NSLocalizedString(
                hasOpenAIAPIKey
                    ? "settings.whisper_openai_key_footer"
                    : "settings.whisper_openai_key_missing_footer",
                comment: "Whisper OpenAI key dependency"
            ))
        }
    }

    /// Apply a transcription-engine choice, intercepting the FluidAudio engine
    /// to trigger a one-time model download (and deferring the change until it
    /// succeeds). Whisper without an OpenAI key is ignored (the row is disabled).
    private func selectTranscriptionEngine(_ engine: TranscriptionEngine, settings: AppSettings) {
        if engine == .whisperAPI && !hasOpenAIAPIKey { return }
        if engine.requiredModelSet == .onDeviceASR && !settings.fluidAudioBatchASRModelsConsented {
            pendingTranscriptionEngine = engine
            showingBatchASRConsent = true
        } else {
            settings.transcriptionEngine = engine
        }
    }

    /// Apply a language-detection choice, intercepting the FluidAudio detector
    /// to trigger the same one-time on-device-ASR model download.
    private func selectLanguageDetectionEngine(_ engine: LanguageDetectionEngine, settings: AppSettings) {
        if engine.requiredModelSet == .onDeviceASR && !settings.fluidAudioBatchASRModelsConsented {
            pendingLanguageDetectionEngine = engine
            showingBatchASRConsent = true
        } else {
            settings.languageDetectionEngine = engine
        }
    }

    @ViewBuilder
    private func recordingSection(settings: AppSettings) -> some View {
        Section {
            Picker(
                NSLocalizedString("settings.mic_pickup", comment: "Microphone"),
                selection: Binding(
                    get: { settings.micPickup },
                    set: { settings.micPickup = $0 }
                )
            ) {
                ForEach(MicPickup.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(
                NSLocalizedString("settings.audio_quality", comment: "Audio quality"),
                selection: Binding(
                    get: { settings.audioQuality },
                    set: { settings.audioQuality = $0 }
                )
            ) {
                ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle(
                NSLocalizedString("settings.live_transcription", comment: "Live transcription"),
                isOn: Binding(
                    get: { settings.liveTranscriptionEnabled },
                    set: { enabled in
                        if enabled && !settings.fluidAudioASRModelsConsented {
                            showingASRConsent = true
                        } else {
                            settings.liveTranscriptionEnabled = enabled
                        }
                    }
                )
            )
            .disabled(downloadingModel != nil)
            if downloadingModel == .liveTranscriptionASR {
                modelDownloadProgressRow
            }
        } header: {
            Text(NSLocalizedString("settings.recording", comment: "Recording"))
        } footer: {
            Text(NSLocalizedString("settings.mic_pickup_footer", comment: "Explains pickup modes"))
        }
    }

    @ViewBuilder
    private func diagnosticsSection(settings: AppSettings) -> some View {
        Section {
            Picker(
                NSLocalizedString("settings.log_level", comment: "Logging level"),
                selection: Binding(
                    get: { settings.logLevel },
                    set: { settings.logLevel = $0 }
                )
            ) {
                ForEach(LogLevel.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text(NSLocalizedString("settings.diagnostics", comment: "Diagnostics"))
        } footer: {
            Text(NSLocalizedString("settings.log_level_footer", comment: "Explains logging levels"))
        }
    }

    /// Indeterminate download indicator shown while a FluidAudio model set is
    /// being fetched. FluidAudio's high-level download API doesn't expose byte
    /// progress, so this is intentionally indeterminate.
    private var modelDownloadProgressRow: some View {
        HStack {
            ProgressView()
            Text(NSLocalizedString("settings.model_download.downloading", comment: "Downloading model"))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func refreshStorage() {
        storageText = AudioFileStore.formattedSize(AudioFileStore.totalAudioBytes())
    }

    private func deleteAllData() {
        try? modelContext.delete(model: Meeting.self)
        try? modelContext.save()
        AudioFileStore.deleteAllAudio()
        refreshStorage()
    }

    /// Downloaded on-device models the user can inspect and remove. Only groups
    /// actually present on disk are listed; deleting one frees its space and
    /// turns the matching feature off so it can be re-downloaded on demand.
    @ViewBuilder
    private var modelsSection: some View {
        let installed = ModelStore.ModelGroup.allCases.filter { (modelSizes[$0] ?? 0) > 0 }
        Section {
            if installed.isEmpty {
                Text(NSLocalizedString("settings.models.none", comment: "No models downloaded"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(installed) { group in
                    HStack {
                        Text(group.displayName)
                        Spacer()
                        Text(AudioFileStore.formattedSize(modelSizes[group] ?? 0))
                            .foregroundStyle(Theme.textSecondary)
                        Button {
                            pendingModelDeletion = group
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                        .disabled(downloadingModel != nil)
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("settings.models", comment: "On-device models"))
        } footer: {
            Text(NSLocalizedString("settings.models_footer", comment: "Models footer"))
        }
    }

    /// Recompute each model group's on-disk size off the main thread.
    private func refreshModelSizes() {
        Task { @MainActor in
            let sizes = await Task.detached {
                var result: [ModelStore.ModelGroup: Int64] = [:]
                for group in ModelStore.ModelGroup.allCases {
                    result[group] = ModelStore.sizeOnDisk(group)
                }
                return result
            }.value
            modelSizes = sizes
        }
    }

    /// Delete a model group from disk and turn off the feature that uses it so the
    /// UI reflects the removal and it can be re-downloaded later.
    private func deleteModel(_ group: ModelStore.ModelGroup) {
        ModelStore.delete(group)
        switch group {
        case .liveTranscription:
            settings.liveTranscriptionEnabled = false
            settings.fluidAudioASRModelsConsented = false
        case .onDeviceLanguage:
            settings.fluidAudioBatchASRModelsConsented = false
            // Turn off the engines that depend on the multilingual on-device
            // model so the UI doesn't point at a now-missing model.
            if settings.transcriptionEngine == .fluidAudioParakeet {
                settings.transcriptionEngine = .appleSpeech
            }
            if settings.languageDetectionEngine == .fluidAudioLID {
                settings.languageDetectionEngine = .byTranscriber
            }
        case .diarization:
            settings.fluidAudioDiarizationModelsConsented = false
            settings.diarizationEngine = .heuristic
        }
        pendingModelDeletion = nil
        refreshModelSizes()
    }

    private var configuredProviders: [AIProvider] {
        _ = keyRevision
        return settings.providers.filter {
            KeychainManager.shared.hasValue(for: $0.keychainAccount)
        }
    }

    private var hasOpenAIAPIKey: Bool {
        _ = keyRevision
        return KeychainManager.shared.hasValue(for: AIProvider.openAI.keychainAccount)
    }

    private func ensureSelectedProviderIsConfigured() {
        let providers = configuredProviders
        guard !providers.isEmpty else { return }
        if !providers.contains(where: { $0.id == settings.aiProviderID }) {
            settings.aiProviderID = providers[0].id
        }
    }

    private func ensureWhisperSelectionIsAllowed() {
        if !hasOpenAIAPIKey && settings.transcriptionEngine == .whisperAPI {
            settings.transcriptionEngine = .appleSpeech
        }
    }
}

/// Consent alerts shown before the first FluidAudio model download for a given feature.
private struct ModelDownloadAlerts: ViewModifier {
    @Binding var showingASRConsent: Bool
    @Binding var showingBatchASRConsent: Bool
    @Binding var showingDiarizationConsent: Bool
    let onConfirmASR: () -> Void
    let onConfirmBatchASR: () -> Void
    let onCancelBatchASR: () -> Void
    let onConfirmDiarization: () -> Void
    let onCancelDiarization: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                NSLocalizedString("settings.model_download.title", comment: "One-time model download"),
                isPresented: $showingASRConsent
            ) {
                Button(NSLocalizedString("settings.model_download.allow", comment: "Allow and Download"), action: onConfirmASR)
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("settings.model_download.message", comment: ""))
            }
            .alert(
                NSLocalizedString("settings.model_download.title", comment: "One-time model download"),
                isPresented: $showingBatchASRConsent
            ) {
                Button(NSLocalizedString("settings.model_download.allow", comment: "Allow and Download"), action: onConfirmBatchASR)
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel, action: onCancelBatchASR)
            } message: {
                Text(NSLocalizedString("settings.model_download.message", comment: ""))
            }
            .alert(
                NSLocalizedString("settings.model_download.title", comment: "One-time model download"),
                isPresented: $showingDiarizationConsent
            ) {
                Button(NSLocalizedString("settings.model_download.allow", comment: "Allow and Download"), action: onConfirmDiarization)
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel, action: onCancelDiarization)
            } message: {
                Text(NSLocalizedString("settings.model_download.message", comment: ""))
            }
    }
}

/// A provider row showing its brand icon, name, and key configuration status.
private struct ProviderRow: View {
    let provider: AIProvider
    let revision: Int

    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(.system(size: 15, weight: .semibold))
                Text(provider.kind.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                let configured = KeychainManager.shared.hasValue(for: provider.keychainAccount)
                HStack(spacing: 5) {
                    Circle()
                        .fill(configured ? Theme.success : Theme.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(configured
                         ? NSLocalizedString("settings.configured", comment: "Configured")
                         : NSLocalizedString("settings.not_configured", comment: "Not configured"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .id(revision)
            }
        }
    }
}

private struct ProviderIcon: View {
    let provider: AIProvider
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(hex: provider.brandHex))
            .frame(width: 32, height: 32)
            .overlay(
                Text(String(provider.displayName.prefix(1)))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

// ProviderEditor, AddProviderView, and SummaryModelPicker live in
// SettingsProviderViews.swift to keep this file under the length limit.

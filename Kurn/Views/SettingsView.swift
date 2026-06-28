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
    // Properties and helpers are `internal` (not `private`) so the view's
    // section builders and actions can live in an `extension` in
    // `SettingsSections.swift`, keeping this file under SwiftLint's length limit.
    @Environment(AppSettings.self) var settings
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss

    @State var storageText = "—"
    @State var showingDeleteConfirm = false
    /// Downloaded FluidAudio model entries, refreshed when the screen appears
    /// and after any download/deletion.
    @State var installedModels: [ModelStore.InstalledModel] = []
    /// Model entry awaiting a delete confirmation, if any.
    @State var pendingModelDeletion: ModelStore.InstalledModel?
    @State var showingAddProvider = false
    @State var showingAddTemplate = false
    /// Bumped after editing a key so the provider rows re-read keychain status.
    @State var keyRevision = 0

    @State var showingASRConsent = false
    @State var showingBatchASRConsent = false
    @State var showingDiarizationConsent = false
    @State var pendingDiarizationEngine: DiarizationEngine?
    /// Engine choices awaiting a successful on-device-ASR model download before
    /// they're applied (both the transcription and language-detection pickers
    /// can require that model).
    @State var pendingTranscriptionEngine: TranscriptionEngine?
    @State var pendingLanguageDetectionEngine: LanguageDetectionEngine?
    @State var showingVADConsent = false
    @State var pendingVADEngine: VADEngine?
    /// Which FluidAudio model set is currently downloading (`nil` when idle), so
    /// the toggle/picker can't be re-triggered mid-download and the matching
    /// section can surface a progress indicator.
    @State var downloadingModel: ModelSet?
    /// Surfaced only if a consented download actually fails — the consent
    /// flags themselves are set after success, so a failure leaves the
    /// feature off and the consent alert available to retry.
    @State var modelDownloadError: AppError?

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
        ) { model in
            Button(NSLocalizedString("settings.models.delete", comment: "Delete model"), role: .destructive) {
                deleteModel(model)
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
                        let before = ModelStore.snapshot()
                        try await ModelDownloadConsent.download(.liveTranscriptionASR)
                        ModelStore.recordDownload(for: .liveTranscription, before: before)
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
                        let before = ModelStore.snapshot()
                        try await ModelDownloadConsent.download(.onDeviceASR)
                        ModelStore.recordDownload(for: .onDeviceLanguage, before: before)
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
                        let before = ModelStore.snapshot()
                        try await ModelDownloadConsent.download(.diarization)
                        ModelStore.recordDownload(for: .diarization, before: before)
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
            },
            showingVADConsent: $showingVADConsent,
            onConfirmVAD: {
                guard let engine = pendingVADEngine else { return }
                pendingVADEngine = nil
                downloadingModel = .vad
                Task {
                    // Keep a finite background window so the download isn't
                    // aborted the moment Settings leaves the foreground.
                    let background = BackgroundActivity()
                    background.begin(name: "ai.kurn.modelDownload")
                    defer { background.end() }
                    do {
                        let before = ModelStore.snapshot()
                        try await ModelDownloadConsent.download(.vad)
                        ModelStore.recordDownload(for: .vad, before: before)
                        settings.fluidAudioVADModelsConsented = true
                        settings.vadEngine = engine
                    } catch let appError as AppError {
                        modelDownloadError = appError
                    } catch {
                        modelDownloadError = .modelDownloadFailed(error.localizedDescription)
                    }
                    downloadingModel = nil
                    refreshModelSizes()
                }
            },
            onCancelVAD: {
                pendingVADEngine = nil
            }
        ))
        .errorAlert($modelDownloadError)
    }
}

// ModelDownloadAlerts, ProviderRow, ProviderIcon, ProviderEditor, AddProviderView,
// and SummaryModelPicker live in SettingsProviderViews.swift; the section
// builders and actions live in an `extension SettingsView` in
// SettingsSections.swift — both to keep this file under SwiftLint's length limit.

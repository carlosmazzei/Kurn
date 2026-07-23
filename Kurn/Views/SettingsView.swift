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
    @Environment(SemanticIndexCoordinator.self) var semanticIndex
    @Environment(WikiCoordinator.self) var wiki
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss

    /// Count of indexed passages shown in the semantic-search section, refreshed
    /// on appear and after a rebuild/clear.
    @State var semanticChunkCount = 0
    /// True while a rebuild is running, so the buttons show progress and can't
    /// be re-triggered.
    @State var isRebuildingIndex = false
    /// Count of wiki articles shown in the meeting-wiki section, refreshed on
    /// appear and after a rebuild/clear.
    @State var wikiArticleCount = 0
    /// True while a wiki rebuild is running, so the buttons show progress and
    /// can't be re-triggered.
    @State var isRebuildingWiki = false

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
    /// Confirmation for the user-triggered temp-file cleanup in Settings.
    @State var showingClearCacheConfirm = false
    /// Current estimate of temp files that can be removed by the manual cleanup.
    @State var cacheCleanupPreview: (files: Int, bytes: Int64) = (0, 0)
    /// Result of the temp-file cleanup (files count + bytes) to show in an alert.
    @State var cacheCleanupResult: (files: Int, bytes: Int64)?

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
    /// Set when "Delete all data" fails to erase the store, so the failure
    /// surfaces instead of the wipe silently doing nothing.
    @State var dataError: AppError?

    /// Share sheet payload for an exported log file, set by `exportLogs()`.
    @State var diagnosticsShareItem: ShareItem?
    /// Surfaced if reading/writing the log export fails.
    @State var logExportError: AppError?
    /// Consent dialog for opting in to on-device MetricKit diagnostic reports.
    @State var showingDiagnosticReportsConsent = false

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

            // MARK: Tags
            Section {
                NavigationLink {
                    TagManagementView()
                } label: {
                    Label(
                        NSLocalizedString("tag.manage", comment: "Manage Tags"),
                        systemImage: "tag"
                    )
                }
                Toggle(
                    NSLocalizedString("settings.auto_tagging", comment: "Auto-tagging"),
                    isOn: $settings.autoTaggingEnabled
                )
            } header: {
                Text(NSLocalizedString("tag.title", comment: "Tags"))
            } footer: {
                Text(NSLocalizedString("settings.auto_tagging_footer", comment: "Auto-tagging footer"))
            }

            // MARK: Semantic search & chat
            semanticSearchSection(settings: settings)

            // MARK: Meeting wiki (cross-meeting synthesis)
            wikiSection(settings: settings)

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

            // MARK: My Data
            Section {
                NavigationLink {
                    UsageInsightsView()
                } label: {
                    Label(
                        NSLocalizedString("usage_insights.title", comment: "Usage Insights"),
                        systemImage: "chart.bar"
                    )
                }
            } footer: {
                Text(NSLocalizedString("usage_insights.footer", comment: "Explains local-only usage data"))
            }

            // MARK: Storage
            Section(NSLocalizedString("settings.storage", comment: "Storage")) {
                LabeledContent(
                    NSLocalizedString("settings.audio_usage", comment: "Audio usage"),
                    value: storageText
                )
                Button {
                    Task { @MainActor in
                        cacheCleanupPreview = await loadCacheCleanupPreview()
                        showingClearCacheConfirm = true
                    }
                } label: {
                    HStack {
                        Label(
                            NSLocalizedString("settings.clear_cache", comment: "Clear temporary files"),
                            systemImage: "trash"
                        )
                        Spacer()
                        Text(
                            String(
                                format: NSLocalizedString("settings.clear_cache.preview", comment: "Reclaimable temp space"),
                                AudioFileStore.formattedSize(cacheCleanupPreview.bytes)
                            )
                        )
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            // MARK: Downloaded models
            modelsSection

            // MARK: About
            Section {
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Label(
                        NSLocalizedString("settings.acknowledgements", comment: "Acknowledgements"),
                        systemImage: "doc.text"
                    )
                }
                Link(destination: URL(string: "https://github.com/sponsors/carlosmazzei")!) {
                    Label(
                        NSLocalizedString("settings.sponsor", comment: "Sponsor Kurn"),
                        systemImage: "heart"
                    )
                }
            } header: {
                Text(NSLocalizedString("settings.about", comment: "About"))
            } footer: {
                Text(NSLocalizedString("settings.appstore_status", comment: "App Store status note"))
            }

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
            refreshCacheCleanupPreview()
            refreshModelSizes()
            ensureSelectedProviderIsConfigured()
            ensureWhisperSelectionIsAllowed()
        }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingModelDeletion != nil },
                set: { if !$0 { pendingModelDeletion = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.models.delete_confirm", comment: "Confirm delete model"),
            message: NSLocalizedString("settings.models.delete_message", comment: "Re-download later"),
            primaryTitle: NSLocalizedString("settings.models.delete", comment: "Delete model"),
            primaryRole: .destructive,
            primaryAction: {
                if let model = pendingModelDeletion {
                    deleteModel(model)
                }
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .onChange(of: keyRevision) { _, _ in
            ensureSelectedProviderIsConfigured()
            ensureWhisperSelectionIsAllowed()
        }
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.delete_all.confirm", comment: "Confirm delete all"),
            message: NSLocalizedString("settings.delete_all.message", comment: ""),
            primaryTitle: NSLocalizedString("settings.delete_all", comment: "Delete All Data"),
            primaryRole: .destructive,
            primaryAction: deleteAllData,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
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
        .errorAlert($dataError)
        .errorAlert($logExportError)
        .sheet(item: $diagnosticsShareItem) { item in
            ActivityView(items: item.urls)
        }
        .kurnDialog(
            isPresented: $showingDiagnosticReportsConsent,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.info,
            title: NSLocalizedString("settings.diagnostic_reports.consent_title", comment: "Enable diagnostic reports"),
            message: NSLocalizedString("settings.diagnostic_reports.consent_message", comment: "Explains on-device diagnostic reports"),
            primaryTitle: NSLocalizedString("settings.diagnostic_reports.enable", comment: "Enable"),
            primaryAction: { settings.diagnosticReportsConsented = true },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: Binding(
                get: { cacheCleanupResult != nil },
                set: { if !$0 { cacheCleanupResult = nil } }
            ),
            iconSystemName: "checkmark.circle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.clear_cache.done", comment: "Temporary files cleared"),
            message: cacheCleanupResult.map { result in
                String(
                    format: NSLocalizedString("settings.clear_cache.result", comment: "Cache cleared result"),
                    result.files,
                    AudioFileStore.formattedSize(result.bytes)
                )
            } ?? "",
            primaryTitle: NSLocalizedString("common.ok", comment: "OK"),
            primaryAction: {}
        )
        .kurnDialog(
            isPresented: $showingClearCacheConfirm,
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.clear_cache.confirm", comment: "Clear temporary files"),
            message: String(
                format: NSLocalizedString("settings.clear_cache.message", comment: "Clear cache message"),
                cacheCleanupPreview.files,
                AudioFileStore.formattedSize(cacheCleanupPreview.bytes)
            ),
            primaryTitle: NSLocalizedString("settings.clear_cache", comment: "Clear temporary files"),
            primaryRole: .destructive,
            primaryAction: {
                Task {
                    let result = await Task.detached(priority: .utility) {
                        TempFileCleaner.forceCleanup()
                    }.value
                    cacheCleanupResult = result
                    refreshStorage()
                    refreshCacheCleanupPreview()
                }
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }
}

// ModelDownloadAlerts, ProviderRow, ProviderIcon, ProviderEditor, AddProviderView,
// and SummaryModelPicker live in SettingsProviderViews.swift; the section
// builders and actions live in an `extension SettingsView` in
// SettingsSections.swift — both to keep this file under SwiftLint's length limit.

//
//  SettingsView.swift
//  MeetSync
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
    @State private var showingAddProvider = false
    /// Bumped after editing a key so the provider rows re-read keychain status.
    @State private var keyRevision = 0

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
            Section {
                Picker(
                    NSLocalizedString("settings.default_mode", comment: "Default mode"),
                    selection: Binding(
                        get: { settings.defaultMode },
                        set: { mode in
                            if mode != .whisperAPI || hasOpenAIAPIKey {
                                settings.defaultMode = mode
                            }
                        }
                    )
                ) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                            .disabled(mode == .whisperAPI && !hasOpenAIAPIKey)
                    }
                }
                .pickerStyle(.segmented)
                Picker(
                    NSLocalizedString("settings.default_language", comment: "Default language"),
                    selection: $settings.defaultLanguage
                ) {
                    ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text(NSLocalizedString("settings.transcription", comment: "Transcription"))
            } footer: {
                Text(NSLocalizedString(
                    hasOpenAIAPIKey
                        ? "settings.whisper_openai_key_footer"
                        : "settings.whisper_openai_key_missing_footer",
                    comment: "Whisper OpenAI key dependency"
                ))
            }

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

            // MARK: Recording
            Section {
                Picker(
                    NSLocalizedString("settings.mic_pickup", comment: "Microphone"),
                    selection: $settings.micPickup
                ) {
                    ForEach(MicPickup.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(
                    NSLocalizedString("settings.audio_quality", comment: "Audio quality"),
                    selection: $settings.audioQuality
                ) {
                    ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text(NSLocalizedString("settings.recording", comment: "Recording"))
            } footer: {
                Text(NSLocalizedString("settings.mic_pickup_footer", comment: "Explains pickup modes"))
            }

            // MARK: Storage
            Section(NSLocalizedString("settings.storage", comment: "Storage")) {
                LabeledContent(
                    NSLocalizedString("settings.audio_usage", comment: "Audio usage"),
                    value: storageText
                )
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
        .onAppear {
            refreshStorage()
            ensureSelectedProviderIsConfigured()
            ensureWhisperSelectionIsAllowed()
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
        if !hasOpenAIAPIKey && settings.defaultMode == .whisperAPI {
            settings.defaultMode = .onDevice
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

/// Editor for a provider's non-secret config plus API key.
private struct ProviderEditor: View {
    let provider: AIProvider
    let onSave: (AIProvider) -> Void
    let onDelete: () -> Void
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = AIProviderKind.openAICompatible
    @State private var baseURLString = ""
    @State private var key = ""
    @State private var showingDeleteConfirm = false

    private var canEditDetails: Bool { !provider.isBuiltIn }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("settings.provider_name", comment: "Provider name"), text: $name)
                    .disabled(!canEditDetails)
                Picker(NSLocalizedString("settings.provider_type", comment: "Provider type"), selection: $kind) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(!canEditDetails)
                TextField(NSLocalizedString("settings.base_url", comment: "Base URL"), text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(!canEditDetails)
            } footer: {
                Text(NSLocalizedString("settings.base_url_footer", comment: "Base URL footer"))
            }

            Section {
                SecureField(
                    NSLocalizedString("settings.api_key", comment: "API Key"),
                    text: $key
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                Text(NSLocalizedString("settings.credentials", comment: "Credentials"))
            } footer: {
                Text(String(
                    format: NSLocalizedString("settings.key_footer", comment: "Stored securely"),
                    provider.displayName
                ))
            }

            if !key.isEmpty {
                Section {
                    Button(role: .destructive) {
                        key = ""
                        KeychainManager.shared.delete(provider.keychainAccount)
                        onChange()
                    } label: {
                        Text(NSLocalizedString("settings.remove_key", comment: "Remove key"))
                    }
                }
            }

            if !provider.isBuiltIn {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Text(NSLocalizedString("settings.delete_provider", comment: "Delete Provider"))
                    }
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEditDetails {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "Save")) {
                        var updated = provider
                        updated.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.kind = kind
                        updated.baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            name = provider.displayName
            kind = provider.kind
            baseURLString = provider.baseURLString
            key = KeychainManager.shared.get(provider.keychainAccount) ?? ""
        }
        .onChange(of: key) { _, newValue in
            KeychainManager.shared.set(newValue, for: provider.keychainAccount)
            onChange()
        }
        .alert(
            NSLocalizedString("settings.delete_provider.confirm", comment: "Delete provider?"),
            isPresented: $showingDeleteConfirm
        ) {
            Button(NSLocalizedString("settings.delete_provider", comment: "Delete Provider"), role: .destructive) {
                onDelete()
                dismiss()
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
        }
    }
}

private struct AddProviderView: View {
    let onAdd: (AIProvider, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = AIProviderKind.openAICompatible
    @State private var baseURLString = AIProviderKind.openAICompatible.defaultBaseURLString
    @State private var key = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("settings.provider_name", comment: "Provider name"), text: $name)
                Picker(NSLocalizedString("settings.provider_type", comment: "Provider type"), selection: $kind) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                TextField(NSLocalizedString("settings.base_url", comment: "Base URL"), text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text(NSLocalizedString("settings.base_url_footer", comment: "Base URL footer"))
            }

            Section(NSLocalizedString("settings.credentials", comment: "Credentials")) {
                SecureField(NSLocalizedString("settings.api_key", comment: "API Key"), text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle(NSLocalizedString("settings.add_provider", comment: "Add Provider"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.save", comment: "Save")) {
                    let provider = AIProvider.custom(
                        displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        kind: kind,
                        baseURLString: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onAdd(provider, key)
                }
                .disabled(!canSave)
            }
        }
        .onChange(of: kind) { _, newValue in
            baseURLString = newValue.defaultBaseURLString
        }
    }
}

private struct SummaryModelPicker: View {
    let settings: AppSettings
    let provider: AIProvider
    let revision: Int

    @State private var models: [String] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private var selectedModel: String {
        settings.summaryModel(for: provider)
    }

    private var pickerModels: [String] {
        let selected = selectedModel
        guard !selected.isEmpty else { return models }
        return models.contains(selected) ? models : [selected] + models
    }

    var body: some View {
        Picker(
            NSLocalizedString("settings.model", comment: "Model"),
            selection: Binding(
                get: { settings.summaryModel(for: provider) },
                set: { settings.setSummaryModel($0, for: provider) }
            )
        ) {
            if pickerModels.isEmpty {
                Text(NSLocalizedString("settings.no_models", comment: "No models")).tag("")
            } else {
                ForEach(pickerModels, id: \.self) { Text($0).tag($0) }
            }
        }
        .disabled(pickerModels.isEmpty)
        .task(id: "\(provider.id)-\(revision)") {
            await loadModels()
        }

        if isLoading {
            HStack {
                ProgressView()
                Text(NSLocalizedString("settings.loading_models", comment: "Loading models"))
                    .foregroundStyle(Theme.textSecondary)
            }
        } else if let errorText {
            Text(errorText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }

        Button {
            Task { await loadModels() }
        } label: {
            Label(NSLocalizedString("settings.refresh_models", comment: "Refresh models"), systemImage: "arrow.clockwise")
        }
        .disabled(isLoading || !KeychainManager.shared.hasValue(for: provider.keychainAccount))
    }

    @MainActor
    private func loadModels() async {
        guard KeychainManager.shared.hasValue(for: provider.keychainAccount) else {
            models = []
            errorText = NSLocalizedString("settings.models_need_key", comment: "Configure key to load models")
            return
        }

        isLoading = true
        errorText = nil
        do {
            let loaded = try await ProviderModelsService().models(for: provider)
            models = loaded
            if settings.summaryModel(for: provider).isEmpty, let first = loaded.first {
                settings.setSummaryModel(first, for: provider)
            }
            if loaded.isEmpty {
                errorText = NSLocalizedString("settings.no_models_loaded", comment: "No models loaded")
            }
        } catch {
            models = []
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

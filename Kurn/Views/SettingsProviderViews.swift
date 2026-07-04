//
//  SettingsProviderViews.swift
//  Kurn
//
//  Provider/model editing screens split out of `SettingsView` to keep that
//  file under SwiftLint's length limit: the editor for an existing provider,
//  the add-provider sheet, and the summary-model picker.
//

import SwiftUI

/// Editor for a provider's non-secret config plus API key.
struct ProviderEditor: View {
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
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.delete_provider.confirm", comment: "Delete provider?"),
            message: provider.displayName,
            primaryTitle: NSLocalizedString("settings.delete_provider", comment: "Delete Provider"),
            primaryRole: .destructive,
            primaryAction: {
                onDelete()
                dismiss()
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }
}

struct AddProviderView: View {
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

struct SummaryModelPicker: View {
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

/// Picker for the cloud transcription (Whisper) model of a given provider,
/// mirroring `SummaryModelPicker` but filtering the provider's model list to
/// Whisper-family models (falling back to the full list when none are tagged).
struct TranscriptionModelPicker: View {
    let settings: AppSettings
    let provider: AIProvider
    let revision: Int

    @State private var models: [String] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private var selectedModel: String {
        settings.transcriptionModel(for: provider)
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
                get: { settings.transcriptionModel(for: provider) },
                set: { settings.setTranscriptionModel($0, for: provider) }
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
            // Prefer Whisper-family models; fall back to the full list when the
            // provider doesn't tag them recognizably.
            let whisperModels = loaded.filter { $0.localizedCaseInsensitiveContains("whisper") }
            models = whisperModels.isEmpty ? loaded : whisperModels
            if settings.transcriptionModel(for: provider).isEmpty, let first = models.first {
                settings.setTranscriptionModel(first, for: provider)
            }
            if models.isEmpty {
                errorText = NSLocalizedString("settings.no_models_loaded", comment: "No models loaded")
            }
        } catch {
            models = []
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Model download consent dialogs

/// Consent dialogs shown before the first FluidAudio model download for a given feature.
struct ModelDownloadAlerts: ViewModifier {
    @Binding var showingASRConsent: Bool
    @Binding var showingBatchASRConsent: Bool
    @Binding var showingDiarizationConsent: Bool
    let onConfirmASR: () -> Void
    let onConfirmBatchASR: () -> Void
    let onCancelBatchASR: () -> Void
    let onConfirmDiarization: () -> Void
    let onCancelDiarization: () -> Void
    @Binding var showingVADConsent: Bool
    let onConfirmVAD: () -> Void
    let onCancelVAD: () -> Void

    func body(content: Content) -> some View {
        content
            .modelDownloadDialog(isPresented: $showingASRConsent, onConfirm: onConfirmASR, onCancel: {})
            .modelDownloadDialog(isPresented: $showingBatchASRConsent, onConfirm: onConfirmBatchASR, onCancel: onCancelBatchASR)
            .modelDownloadDialog(isPresented: $showingDiarizationConsent, onConfirm: onConfirmDiarization, onCancel: onCancelDiarization)
            .modelDownloadDialog(isPresented: $showingVADConsent, onConfirm: onConfirmVAD, onCancel: onCancelVAD)
    }
}

private extension View {
    func modelDownloadDialog(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        kurnDialog(
            isPresented: isPresented,
            iconSystemName: "arrow.down.circle.fill",
            iconTint: Theme.info,
            title: NSLocalizedString("settings.model_download.title", comment: "One-time model download"),
            message: NSLocalizedString("settings.model_download.message", comment: ""),
            primaryTitle: NSLocalizedString("settings.model_download.allow", comment: "Allow and Download"),
            primaryAction: onConfirm,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: onCancel
        )
    }
}

// MARK: - Provider row

/// A provider row showing its brand icon, name, and key configuration status.
struct ProviderRow: View {
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

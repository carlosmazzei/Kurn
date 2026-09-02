//
//  SettingsProviderViews.swift
//  Kurn
//
//  Provider/model editing screens split out of `SettingsView` to keep that
//  file under SwiftLint's length limit: the editor for an existing provider,
//  the add-provider sheet, and the summary-model picker.
//

import KurnCore
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
    /// The key as last read from (or written to) the Keychain, so Save only
    /// touches the Keychain when the field actually changed (H7 PR 14) —
    /// editing just the name/URL must not risk failing over an untouched key.
    @State private var originalKey = ""
    @State private var showingDeleteConfirm = false
    @State private var saveError: AppError?

    private var canEditDetails: Bool { !provider.isBuiltIn }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        LLMHTTP.isValidBaseURL(baseURLString)
    }

    var body: some View {
        Form {
            if provider.kind == .appleOnDevice {
                Section {
                    OnDeviceStatusLabel(reason: OnDeviceModelAvailability.unavailableReason)
                } header: {
                    Text(NSLocalizedString("settings.on_device_status_title", comment: "On-Device Status"))
                } footer: {
                    Text(NSLocalizedString("settings.on_device_footer", comment: "Runs entirely on-device"))
                }
            } else {
                Section {
                    TextField(NSLocalizedString("settings.provider_name", comment: "Provider name"), text: $name)
                        .disabled(!canEditDetails)
                    Picker(NSLocalizedString("settings.provider_type", comment: "Provider type"), selection: $kind) {
                        ForEach(AIProviderKind.networkCases) { Text($0.displayName).tag($0) }
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
                        // Clears the field only — the Keychain isn't touched
                        // until Save, same as every other field here (H7 PR 14).
                        Button(role: .destructive) {
                            key = ""
                        } label: {
                            Text(NSLocalizedString("settings.remove_key", comment: "Remove key"))
                        }
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
                        commitAndSave()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            name = provider.displayName
            kind = provider.kind
            baseURLString = provider.baseURLString
            switch KeychainManager.shared.get(provider.keychainAccount) {
            case .found(let value):
                key = value
                originalKey = value
            case .absent:
                key = ""
                originalKey = ""
            case .failed(let reason):
                // Leaves the field blank rather than claiming "no key" — a
                // locked/denied/transient read must not read the same as
                // "never configured" (H7 PR 14). Editing another field and
                // saving still works: `commitAndSave` only touches the
                // Keychain when `key != originalKey`, so an unread key is
                // never clobbered by a Save the user didn't intend to touch it.
                key = ""
                originalKey = ""
                saveError = .keychainAccessFailed(reason.rawValue)
            }
        }
        .errorAlert($saveError)
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

    /// Commits every field on explicit Save (H7 PR 14) — the Keychain write
    /// only happens here, only when `key` actually changed, and only after
    /// `canSave` has already confirmed the URL is valid. A failed write
    /// surfaces `saveError` and leaves the sheet open (no `onSave`/`dismiss`)
    /// so the user can retry without losing their other edits — the same
    /// "keep the previous state until the replacement is durable" shape H5
    /// PR 12 established for transcripts.
    private func commitAndSave() {
        if key != originalKey {
            let outcome: KeychainWriteOutcome = key.isEmpty
                ? KeychainManager.shared.delete(provider.keychainAccount)
                : KeychainManager.shared.set(key, for: provider.keychainAccount)
            guard case .success = outcome else {
                if case .failed(let reason) = outcome {
                    saveError = .keychainAccessFailed(reason.rawValue)
                }
                return
            }
            originalKey = key
            onChange()
        }
        var updated = provider
        updated.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.kind = kind
        updated.baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(updated)
        dismiss()
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
        LLMHTTP.isValidBaseURL(baseURLString)
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("settings.provider_name", comment: "Provider name"), text: $name)
                Picker(NSLocalizedString("settings.provider_type", comment: "Provider type"), selection: $kind) {
                    ForEach(AIProviderKind.networkCases) { Text($0.displayName).tag($0) }
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

    var body: some View {
        ProviderModelPicker(
            provider: provider,
            revision: revision,
            selection: Binding(
                get: { settings.summaryModel(for: provider) },
                set: { settings.setSummaryModel($0, for: provider) }
            )
        )
    }
}

/// Picker for the cloud transcription (Whisper) model of a given provider,
/// mirroring `SummaryModelPicker` but filtering the provider's model list to
/// Whisper-family models (falling back to the full list when none are tagged).
struct TranscriptionModelPicker: View {
    let settings: AppSettings
    let provider: AIProvider
    let revision: Int

    var body: some View {
        ProviderModelPicker(
            provider: provider,
            revision: revision,
            selection: Binding(
                get: { settings.transcriptionModel(for: provider) },
                set: { settings.setTranscriptionModel($0, for: provider) }
            ),
            filter: { loaded in
                let whisperModels = loaded.filter { $0.localizedCaseInsensitiveContains("whisper") }
                return whisperModels.isEmpty ? loaded : whisperModels
            }
        )
    }
}

/// Shared model picker for a provider's remote model list: loads the list via
/// `ProviderModelsService`, keeps the current selection visible even when the
/// list doesn't contain it, defaults an empty selection to the first loaded
/// model, and offers a refresh button. `filter` narrows the loaded list
/// (e.g. to Whisper-family models for transcription).
private struct ProviderModelPicker: View {
    let provider: AIProvider
    let revision: Int
    let selection: Binding<String>
    var filter: (@MainActor ([String]) -> [String])?

    @State private var models: [String] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private var pickerModels: [String] {
        let selected = selection.wrappedValue
        guard !selected.isEmpty else { return models }
        return models.contains(selected) ? models : [selected] + models
    }

    var body: some View {
        Picker(
            NSLocalizedString("settings.model", comment: "Model"),
            selection: selection
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
                .font(Theme.caption)
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
            models = filter?(loaded) ?? loaded
            if selection.wrappedValue.isEmpty, let first = models.first {
                selection.wrappedValue = first
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

/// Consent dialogs shown before the first FluidAudio model download for a given
/// feature, plus the failure alert. Every Settings screen that can start a
/// download attaches this, so the dialog follows whichever screen triggered it.
struct ModelDownloadAlerts: ViewModifier {
    @Bindable var downloads: ModelDownloadController
    let settings: AppSettings

    func body(content: Content) -> some View {
        content
            .modelDownloadDialog(
                isPresented: $downloads.showingASRConsent,
                onConfirm: { downloads.confirmLiveTranscriptionASR(settings: settings) },
                onCancel: {}
            )
            .modelDownloadDialog(
                isPresented: $downloads.showingBatchASRConsent,
                onConfirm: { downloads.confirmBatchASR(settings: settings) },
                onCancel: { downloads.cancelBatchASR() }
            )
            .modelDownloadDialog(
                isPresented: $downloads.showingDiarizationConsent,
                onConfirm: { downloads.confirmDiarization(settings: settings) },
                onCancel: { downloads.cancelDiarization() }
            )
            .modelDownloadDialog(
                isPresented: $downloads.showingSherpaOnnxConsent,
                // Distinct copy: CPU-only (no ANE), a different download size,
                // and a different vendor than the shared FluidAudio message.
                messageKey: "settings.model_download.message_sherpa_onnx",
                onConfirm: { downloads.confirmSherpaOnnx(settings: settings) },
                onCancel: { downloads.cancelSherpaOnnx() }
            )
            .modelDownloadDialog(
                isPresented: $downloads.showingVADConsent,
                onConfirm: { downloads.confirmVAD(settings: settings) },
                onCancel: { downloads.cancelVAD() }
            )
            .modelDownloadDialog(
                isPresented: $downloads.showingWhisperCppConsent,
                // The shared message names FluidAudio; whisper.cpp weights come
                // from elsewhere and are much larger, so it gets its own text.
                messageKey: "settings.model_download.message_whisper_cpp",
                onConfirm: { downloads.confirmWhisperCpp(settings: settings) },
                onCancel: { downloads.cancelWhisperCpp() }
            )
            // Picking the engine has to also pick a size, since the size picker
            // only appears once whisper.cpp *is* the selected engine — i.e. after
            // the download it would otherwise have chosen for the user.
            .confirmationDialog(
                NSLocalizedString("settings.whisper_cpp.choose_model", comment: "Choose a Whisper model"),
                isPresented: $downloads.showingWhisperCppModelChoice,
                titleVisibility: .visible
            ) {
                ForEach(WhisperCppModel.allCases) { model in
                    Button(Self.choiceLabel(for: model)) {
                        downloads.chooseWhisperCppModel(model, settings: settings)
                    }
                }
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {
                    downloads.cancelWhisperCpp()
                }
            } message: {
                Text(NSLocalizedString("settings.model_download.message_whisper_cpp", comment: ""))
            }
            .errorAlert($downloads.error)
    }

    /// Size to download, or a note that it's already on disk — so the cost of
    /// each option is visible before the user commits to one.
    private static func choiceLabel(for model: WhisperCppModel) -> String {
        let detail = WhisperCppModelDownloader.isInstalled(model)
            ? NSLocalizedString("settings.models.installed", comment: "Already downloaded")
            : ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file)
        return "\(model.displayName) · \(detail)"
    }
}

extension View {
    /// Attach the model-download consent dialogs and failure alert.
    func modelDownloadAlerts(
        _ downloads: ModelDownloadController,
        settings: AppSettings
    ) -> some View {
        modifier(ModelDownloadAlerts(downloads: downloads, settings: settings))
    }
}

/// Download indicator backed by FluidAudio's byte-level progress reporting.
struct ModelDownloadProgressRow: View {
    let progress: ModelDownloadStatus?
    /// H7 PR 15: `nil` renders no cancel button (the row's previous shape),
    /// so a screen only needs to pass this once `ModelDownloadController`
    /// has something to cancel.
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(phaseLabel)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let progress {
                    Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                if let onCancel {
                    Button(role: .cancel) {
                        onCancel()
                    } label: {
                        Text(NSLocalizedString("common.cancel", comment: "Cancel"))
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let progress {
                ProgressView(value: progress.fractionCompleted)
            } else {
                ProgressView()
            }
        }
    }

    private var phaseLabel: String {
        switch progress?.phase {
        case .preparing:
            NSLocalizedString("settings.model_download.preparing", comment: "Preparing model")
        case .compiling:
            NSLocalizedString("settings.model_download.compiling", comment: "Compiling model")
        case .downloading, nil:
            NSLocalizedString("settings.model_download.downloading", comment: "Downloading model")
        }
    }
}

private extension View {
    func modelDownloadDialog(
        isPresented: Binding<Bool>,
        messageKey: String = "settings.model_download.message",
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        kurnDialog(
            isPresented: isPresented,
            iconSystemName: "arrow.down.circle.fill",
            iconTint: Theme.info,
            title: NSLocalizedString("settings.model_download.title", comment: "One-time model download"),
            message: NSLocalizedString(messageKey, comment: ""),
            primaryTitle: NSLocalizedString("settings.model_download.allow", comment: "Allow and Download"),
            primaryAction: onConfirm,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: onCancel
        )
    }
}

// MARK: - Provider row

/// A provider row showing its brand icon, name, and configuration/availability
/// status. The on-device provider has no key to check, so it reads
/// `SystemLanguageModel` availability instead — see `OnDeviceStatusLabel`.
struct ProviderRow: View {
    let provider: AIProvider
    let revision: Int

    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(Theme.subheadlineEmphasized)
                Text(provider.kind.displayName)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                if provider.kind == .appleOnDevice {
                    OnDeviceStatusLabel(reason: OnDeviceModelAvailability.unavailableReason)
                        .id(revision)
                } else {
                    let configured = KeychainManager.shared.hasValue(for: provider.keychainAccount)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(configured ? Theme.success : Theme.textTertiary)
                            .frame(width: 6, height: 6)
                        Text(configured
                             ? NSLocalizedString("settings.configured", comment: "Configured")
                             : NSLocalizedString("settings.not_configured", comment: "Not configured"))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .id(revision)
                }
            }
        }
    }
}

/// Shared status dot + label for the on-device provider, used by both
/// `ProviderRow` and `ProviderEditor` so the two never drift.
private struct OnDeviceStatusLabel: View {
    let reason: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(reason == nil ? Theme.success : Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(reason ?? NSLocalizedString("settings.on_device_available", comment: "Available on this device"))
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
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
                    .font(.system(.subheadline, design: .default, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

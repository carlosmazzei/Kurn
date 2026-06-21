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
    /// Bumped after editing a key so the provider rows re-read keychain status.
    @State private var keyRevision = 0

    var body: some View {
        @Bindable var settings = settings

        Form {
            // MARK: AI providers
            Section(NSLocalizedString("settings.providers", comment: "AI Providers")) {
                ForEach(AIProvider.allCases) { provider in
                    NavigationLink {
                        ProviderKeyEditor(provider: provider, onChange: { keyRevision += 1 })
                    } label: {
                        ProviderRow(provider: provider, revision: keyRevision)
                    }
                }
            }

            // MARK: Transcription
            Section(NSLocalizedString("settings.transcription", comment: "Transcription")) {
                Picker(
                    NSLocalizedString("settings.default_mode", comment: "Default mode"),
                    selection: $settings.defaultMode
                ) {
                    ForEach(TranscriptionMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(
                    NSLocalizedString("settings.default_language", comment: "Default language"),
                    selection: $settings.defaultLanguage
                ) {
                    ForEach(MeetingLanguage.allCases) { Text($0.displayName).tag($0) }
                }
            }

            // MARK: Summary
            Section(NSLocalizedString("settings.summary", comment: "Summary")) {
                Picker(
                    NSLocalizedString("settings.provider", comment: "Provider"),
                    selection: $settings.aiProvider
                ) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(
                    NSLocalizedString("settings.model", comment: "Model"),
                    selection: Binding(
                        get: { settings.summaryModel(for: settings.aiProvider) },
                        set: { settings.setSummaryModel($0, for: settings.aiProvider) }
                    )
                ) {
                    ForEach(settings.aiProvider.availableModels, id: \.self) { Text($0).tag($0) }
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
        .onAppear { refreshStorage() }
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
                let configured = KeychainManager.shared.hasValue(for: provider.keychainKey)
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

/// Editor for a single provider's API key (stored in the Keychain).
private struct ProviderKeyEditor: View {
    let provider: AIProvider
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                SecureField(
                    NSLocalizedString("settings.api_key", comment: "API Key"),
                    text: $key
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                Text(provider.displayName)
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
                        KeychainManager.shared.delete(provider.keychainKey)
                        onChange()
                    } label: {
                        Text(NSLocalizedString("settings.remove_key", comment: "Remove key"))
                    }
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { key = KeychainManager.shared.get(provider.keychainKey) ?? "" }
        .onChange(of: key) { _, newValue in
            KeychainManager.shared.set(newValue, for: provider.keychainKey)
            onChange()
        }
    }
}

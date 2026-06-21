//
//  SettingsView.swift
//  MeetSync
//
//  App configuration: AI provider + API keys (stored in Keychain), default
//  transcription mode and language, storage usage, and destructive data reset.
//

import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var storageText = "—"
    @State private var showingDeleteConfirm = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section(NSLocalizedString("settings.provider", comment: "AI Provider")) {
                Picker(
                    NSLocalizedString("settings.provider", comment: "AI Provider"),
                    selection: $settings.aiProvider
                ) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                SecureField(
                    NSLocalizedString("settings.openai_key", comment: "OpenAI API Key"),
                    text: $openAIKey
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: openAIKey) { _, newValue in
                    KeychainManager.shared.set(newValue, for: .openAI)
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text(NSLocalizedString("settings.openai_footer", comment: "Whisper + GPT"))
            }

            Section {
                SecureField(
                    NSLocalizedString("settings.anthropic_key", comment: "Anthropic API Key"),
                    text: $anthropicKey
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: anthropicKey) { _, newValue in
                    KeychainManager.shared.set(newValue, for: .anthropic)
                }
            } header: {
                Text("Anthropic")
            } footer: {
                Text(NSLocalizedString("settings.anthropic_footer", comment: "Claude"))
            }

            Section(NSLocalizedString("settings.defaults", comment: "Defaults")) {
                Picker(
                    NSLocalizedString("settings.default_mode", comment: "Default mode"),
                    selection: $settings.defaultMode
                ) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker(
                    NSLocalizedString("settings.default_language", comment: "Default language"),
                    selection: $settings.defaultLanguage
                ) {
                    ForEach(MeetingLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }

            Section {
                Picker(
                    NSLocalizedString("settings.mic_pickup", comment: "Microphone pickup"),
                    selection: $settings.micPickup
                ) {
                    ForEach(MicPickup.allCases) { pickup in
                        Text(pickup.displayName).tag(pickup)
                    }
                }
            } header: {
                Text(NSLocalizedString("settings.mic_pickup", comment: "Microphone pickup"))
            } footer: {
                Text(NSLocalizedString("settings.mic_pickup_footer", comment: "Explains pickup modes"))
            }

            Section(NSLocalizedString("settings.storage", comment: "Storage")) {
                LabeledContent(
                    NSLocalizedString("settings.audio_usage", comment: "Audio usage"),
                    value: storageText
                )
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
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
        .onAppear(perform: load)
        .confirmationDialog(
            NSLocalizedString("settings.delete_all.confirm", comment: "Confirm delete all"),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(
                NSLocalizedString("settings.delete_all", comment: "Delete All Data"),
                role: .destructive
            ) {
                deleteAllData()
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.delete_all.message", comment: ""))
        }
    }

    private func load() {
        openAIKey = KeychainManager.shared.get(.openAI) ?? ""
        anthropicKey = KeychainManager.shared.get(.anthropic) ?? ""
        refreshStorage()
    }

    private func refreshStorage() {
        storageText = AudioFileStore.formattedSize(AudioFileStore.totalAudioBytes())
    }

    private func deleteAllData() {
        // Cascade-deletes recordings/transcripts/speakers/summaries.
        try? modelContext.delete(model: Meeting.self)
        try? modelContext.save()
        AudioFileStore.deleteAllAudio()
        refreshStorage()
    }
}

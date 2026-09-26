//
//  ReadAloudSettingsView.swift
//  Kurn
//
//  Who reads summaries, wiki articles and documents aloud, in which voice and
//  at what speed. The on-device voice is the default and always listed; a
//  cloud provider appears once it has a key and can speak (OpenAI-compatible,
//  ElevenLabs, Gemini). Choosing one is the opt-in for sending the text being
//  read to that provider, which the footer says in so many words.
//

import AVFoundation
import SwiftUI

struct ReadAloudSettingsView: View {
    /// Bumped by the providers screen when a key is added/removed, so the list
    /// of speaking providers re-reads the Keychain.
    var keyRevision: Int = 0

    @Environment(AppSettings.self) private var settings

    /// A fixed owner for the sample, so leaving the screen stops only it.
    private static let previewOwner = UUID()

    private var speakingProviders: [AIProvider] {
        _ = keyRevision
        return settings.providers.filter(\.isUsableForSpeech)
    }

    private var provider: AIProvider { settings.speechProvider }

    var body: some View {
        Form {
            Section {
                Picker(
                    NSLocalizedString("settings.provider", comment: "Provider"),
                    selection: providerBinding
                ) {
                    ForEach(speakingProviders) { Text($0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("settings.readAloud.provider")
                if provider.speechSynthesisAPI == .system {
                    systemVoicePicker
                } else {
                    cloudVoiceRows
                }
            } header: {
                Text(NSLocalizedString("settings.read_aloud.voice_section", comment: "Voice"))
            } footer: {
                Text(provider.speechSynthesisAPI == .system
                    ? NSLocalizedString("settings.read_aloud.on_device_footer", comment: "On-device voice footer")
                    : String(
                        format: NSLocalizedString("settings.read_aloud.cloud_footer", comment: "Cloud voice privacy footer"),
                        provider.displayName
                    ))
            }

            Section(NSLocalizedString("settings.read_aloud.speed", comment: "Speed")) {
                Picker(NSLocalizedString("settings.read_aloud.speed", comment: "Speed"), selection: rateBinding) {
                    ForEach(ReadAloudPreferences.rateOptions, id: \.self) { rate in
                        Text(rate.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(rate)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ReadAloudControl(item: previewItem)
            } header: {
                Text(NSLocalizedString("settings.read_aloud.preview", comment: "Preview"))
            } footer: {
                Text(NSLocalizedString("settings.read_aloud.preview_footer", comment: "Where read aloud appears"))
            }
        }
        .navigationTitle(NSLocalizedString("settings.read_aloud.title", comment: "Read Aloud"))
        .onDisappear { ReadAloudController.shared.stop(owner: Self.previewOwner) }
    }

    // MARK: - Voice rows

    private var systemVoicePicker: some View {
        Picker(
            NSLocalizedString("settings.read_aloud.voice", comment: "Voice"),
            selection: voiceBinding
        ) {
            Text(NSLocalizedString("settings.read_aloud.voice_automatic", comment: "Automatic voice")).tag("")
            ForEach(Self.systemVoices, id: \.identifier) { voice in
                Text(Self.label(for: voice)).tag(voice.identifier)
            }
        }
        .pickerStyle(.navigationLink)
    }

    @ViewBuilder
    private var cloudVoiceRows: some View {
        let voices = provider.suggestedSpeechVoices
        let currentVoice = settings.readAloud.voice(for: provider)
        Picker(
            NSLocalizedString("settings.read_aloud.voice", comment: "Voice"),
            selection: voiceBinding
        ) {
            ForEach(voices) { Text($0.name).tag($0.id) }
            if !currentVoice.isEmpty, !voices.contains(where: { $0.id == currentVoice }) {
                Text(currentVoice).tag(currentVoice)
            }
        }
        TextField(
            NSLocalizedString("settings.read_aloud.custom_voice", comment: "Custom voice"),
            text: customBinding(\.voices)
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

        let models = provider.suggestedSpeechModels
        let currentModel = settings.readAloud.model(for: provider)
        Picker(
            NSLocalizedString("settings.model", comment: "Model"),
            selection: modelBinding
        ) {
            ForEach(models, id: \.self) { Text($0).tag($0) }
            if !currentModel.isEmpty, !models.contains(currentModel) {
                Text(currentModel).tag(currentModel)
            }
        }
        TextField(
            NSLocalizedString("settings.read_aloud.custom_model", comment: "Custom model"),
            text: customBinding(\.models)
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    // MARK: - Bindings

    private var providerBinding: Binding<String> {
        Binding(
            get: { provider.id },
            set: { newValue in
                ReadAloudController.shared.stop()
                settings.readAloud.providerID = newValue
            }
        )
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: {
                provider.speechSynthesisAPI == .system
                    ? settings.readAloud.voices[provider.id] ?? ""
                    : settings.readAloud.voice(for: provider)
            },
            set: { settings.readAloud.voices[provider.id] = $0 }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.readAloud.model(for: provider) },
            set: { settings.readAloud.models[provider.id] = $0 }
        )
    }

    /// Free text for a voice or model the suggestions do not list. Empty
    /// means "use the provider's default".
    private func customBinding(_ keyPath: WritableKeyPath<ReadAloudPreferences, [String: String]>) -> Binding<String> {
        Binding(
            get: { settings.readAloud[keyPath: keyPath][provider.id] ?? "" },
            set: { settings.readAloud[keyPath: keyPath][provider.id] = $0 }
        )
    }

    private var rateBinding: Binding<Float> {
        Binding(
            get: { settings.readAloud.rate },
            set: { settings.readAloud.rate = $0 }
        )
    }

    // MARK: - Preview

    private var previewItem: ReadAloudItem {
        ReadAloudItem(
            id: "preview:\(provider.id)",
            ownerID: Self.previewOwner,
            title: NSLocalizedString("settings.read_aloud.title", comment: "Read Aloud"),
            subtitle: provider.displayName,
            spokenText: NSLocalizedString("settings.read_aloud.sample", comment: "Sample sentence read aloud")
        )
    }

    // MARK: - System voices

    /// Installed voices, grouped by language with the best quality first. The
    /// list is only known at runtime and changes when the user downloads a
    /// voice in iOS Settings.
    private static var systemVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return lhs.name < rhs.name
        }
    }

    private static func label(for voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(voice.name) — \(language)"
    }
}

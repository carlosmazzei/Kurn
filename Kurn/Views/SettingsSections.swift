//
//  SettingsSections.swift
//  Kurn
//
//  Helpers shared by the Settings hub and its section screens: which providers
//  actually have a key, the invariants that keep the selected summary and
//  transcription providers valid, and the destructive reset.
//
//  The section bodies these used to sit next to now live one per screen in
//  `Views/Settings/`.
//

import SwiftData
import SwiftUI

extension AppSettings {

    /// Providers with a key in the Keychain — the only ones that can be selected
    /// for summaries. Screens that show these read their `keyRevision` counter
    /// first, so the list re-derives after a key is added or removed.
    var configuredProviders: [AIProvider] {
        providers.filter { KeychainManager.shared.hasValue(for: $0.keychainAccount) }
    }

    /// Configured providers that can run cloud (Whisper) transcription — the
    /// candidate list for the transcription-provider picker.
    var configuredTranscriptionProviders: [AIProvider] {
        configuredProviders.filter(\.supportsTranscription)
    }
}

extension SettingsView {

    func ensureSelectedProviderIsConfigured() {
        let providers = settings.configuredProviders
        guard !providers.isEmpty else { return }
        if !providers.contains(where: { $0.id == settings.aiProviderID }) {
            settings.aiProviderID = providers[0].id
        }
    }

    func ensureWhisperSelectionIsAllowed() {
        guard settings.transcriptionEngine == .whisperAPI else { return }
        // Revert to on-device only when no transcription-capable provider has a
        // key; otherwise keep Whisper and repoint at a valid provider if the
        // selected one lost its key or was removed.
        let providers = settings.configuredTranscriptionProviders
        if providers.isEmpty {
            settings.transcriptionEngine = .appleSpeech
        } else if !providers.contains(where: { $0.id == settings.transcriptionProviderID }) {
            settings.transcriptionProviderID = providers[0].id
        }
    }

    func deleteAllData() {
        do {
            try modelContext.delete(model: Meeting.self)
            try modelContext.save()
        } catch {
            AppLog.persistence.atError.error("Failed to delete all data: \(error.localizedDescription, privacy: .public)")
            dataError = .persistenceFailed(error.localizedDescription)
            return
        }
        AudioFileStore.deleteAllAudio()
    }
}

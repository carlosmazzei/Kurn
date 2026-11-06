//
//  AppSettings+Providers.swift
//  Kurn
//

import Foundation
import KurnCore

extension AppSettings {
    var aiProvider: AIProvider {
        providers.first(where: { $0.id == aiProviderID }) ?? providers.first ?? .openAI
    }

    /// Resolve `transcriptionProviderID` to a configured provider, falling back
    /// to the first transcription-capable provider (or OpenAI) if it's stale or
    /// points at a provider that can't transcribe.
    var transcriptionProvider: AIProvider {
        if let provider = providers.first(where: { $0.id == transcriptionProviderID }),
           provider.supportsTranscription {
            return provider
        }
        return providers.first(where: { $0.supportsTranscription }) ?? .openAI
    }

    /// The provider that reads aloud: the stored choice while it still exists
    /// and has its key, otherwise the always-available on-device voice — so
    /// removing a key never leaves reading aloud pointing at a dead provider.
    var speechProvider: AIProvider {
        providers.first { $0.id == readAloud.providerID && $0.isUsableForSpeech } ?? .appleOnDevice
    }

    /// Selected summary model for a provider, falling back to its default.
    func summaryModel(for provider: AIProvider) -> String {
        let stored = summaryModels[provider.rawValue]
        if let stored, !stored.isEmpty { return stored }
        return provider.defaultModel
    }

    func setSummaryModel(_ model: String, for provider: AIProvider) {
        summaryModels[provider.rawValue] = model
    }

    /// Selected transcription model for a provider, falling back to its default
    /// Whisper model (`whisper-1`, or `whisper-large-v3` for Groq).
    func transcriptionModel(for provider: AIProvider) -> String {
        let stored = transcriptionModels[provider.rawValue]
        if let stored, !stored.isEmpty { return stored }
        return provider.defaultTranscriptionModel
    }

    func setTranscriptionModel(_ model: String, for provider: AIProvider) {
        transcriptionModels[provider.rawValue] = model
    }

    func addProvider(_ provider: AIProvider) {
        providers.append(provider)
        aiProviderID = provider.id
    }

    func updateProvider(_ provider: AIProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        // An edited kind can change what the provider supports, so the
        // selections are re-checked like after a key change.
        credentials.invalidate()
    }

    func removeProvider(_ provider: AIProvider) {
        guard !provider.isBuiltIn else { return }
        providers.removeAll { $0.id == provider.id }
        summaryModels[provider.id] = nil
        transcriptionModels[provider.id] = nil
        if aiProviderID == provider.id {
            aiProviderID = providers.first?.id ?? AIProvider.openAI.id
        }
        if transcriptionProviderID == provider.id {
            transcriptionProviderID = providers.first(where: { $0.supportsTranscription })?.id
                ?? AIProvider.openAI.id
        }
        credentials.saveKey("", for: provider)
    }
}

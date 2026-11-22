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

    /// The provider that writes meeting Wiki pages: the explicit pick while
    /// it still resolves to a configured provider, else the summary provider
    /// ("Same as summaries").
    var wikiGenerationProvider: AIProvider {
        if let wikiProviderID, let provider = providers.first(where: { $0.id == wikiProviderID }) {
            return provider
        }
        return aiProvider
    }

    /// The model the Wiki writer runs with. An explicit `wikiModels` entry
    /// wins; while the Wiki provider IS the summary provider ("Same as
    /// summaries" or the same pick) the summary model is inherited, and a
    /// different provider without a Wiki pick falls back to its default.
    var wikiGenerationModel: String {
        let provider = wikiGenerationProvider
        if let stored = wikiModels[provider.rawValue], !stored.isEmpty { return stored }
        if provider.id == aiProvider.id { return summaryModel(for: provider) }
        return provider.defaultModel
    }

    /// Selected Wiki model for a provider, falling back to its default.
    func wikiModel(for provider: AIProvider) -> String {
        let stored = wikiModels[provider.rawValue]
        if let stored, !stored.isEmpty { return stored }
        return provider.defaultModel
    }

    func setWikiModel(_ model: String, for provider: AIProvider) {
        wikiModels[provider.rawValue] = model
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
        let movedDestination = cloudConsentDestination(for: providers[index]) != cloudConsentDestination(for: provider)
        providers[index] = provider
        // Editing the summary provider's endpoint is choosing a new
        // destination, recorded like selecting a provider (CLAUDE.md, "Cloud consent").
        if movedDestination, provider.id == aiProviderID, provider.supportsSummarization {
            grantCloudConsent(provider, for: .onRequest)
            if wikiEnabled || correctionEnabled || aiTitleCloudEnabled { grantCloudConsent(provider, for: .automatic) }
        }
        // An edited kind can change what the provider supports, so the
        // selections are re-checked like after a key change.
        credentials.invalidate()
    }

    func removeProvider(_ provider: AIProvider) {
        guard !provider.isBuiltIn else { return }
        providers.removeAll { $0.id == provider.id }
        summaryModels[provider.id] = nil
        wikiModels[provider.id] = nil
        transcriptionModels[provider.id] = nil
        if wikiProviderID == provider.id {
            // Back to "Same as summaries" — an in-place removal is not a
            // choice, so it records no grant for the fallback.
            wikiProviderID = nil
        }
        if aiProviderID == provider.id {
            isRepointingSelection = true
            aiProviderID = providers.first?.id ?? AIProvider.openAI.id
            isRepointingSelection = false
        }
        if transcriptionProviderID == provider.id {
            transcriptionProviderID = providers.first(where: { $0.supportsTranscription })?.id
                ?? AIProvider.openAI.id
        }
        credentials.saveKey("", for: provider)
    }
}

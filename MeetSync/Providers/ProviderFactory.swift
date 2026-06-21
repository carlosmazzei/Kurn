//
//  ProviderFactory.swift
//  MeetSync
//
//  Builds the correct `LLMProvider` from settings + keychain. Centralizes the
//  "do we have a key?" check so call sites get a clear `AppError.noAPIKey`.
//

import Foundation

enum ProviderFactory {
    /// Build the summary provider chosen in Settings. Throws `.noAPIKey` when the
    /// selected provider has no stored key.
    static func summaryProvider(for provider: AIProvider, model: String) throws -> LLMProvider {
        let key = KeychainManager.shared.get(provider.keychainKey) ?? ""
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }
        let model = model.isEmpty ? provider.defaultModel : model
        switch provider {
        case .openAI:
            return OpenAIProvider(apiKey: key, model: model)
        case .anthropic:
            return AnthropicProvider(apiKey: key, model: model)
        case .google:
            return GoogleProvider(apiKey: key, model: model)
        case .groq:
            return GroqProvider(apiKey: key, model: model)
        }
    }

    /// Cloud transcription always uses OpenAI Whisper regardless of the summary
    /// provider, so it needs the OpenAI key specifically.
    static func whisperProvider() throws -> OpenAIProvider {
        let key = KeychainManager.shared.get(.openAI) ?? ""
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: AIProvider.openAI.displayName) }
        return OpenAIProvider(apiKey: key)
    }
}

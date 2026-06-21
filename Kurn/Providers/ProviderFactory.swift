//
//  ProviderFactory.swift
//  Kurn
//
//  Builds the correct `LLMProvider` from settings + keychain. Centralizes the
//  "do we have a key?" check so call sites get a clear `AppError.noAPIKey`.
//

import Foundation

enum ProviderFactory {
    /// Build the summary provider chosen in Settings. Throws `.noAPIKey` when the
    /// selected provider has no stored key.
    static func summaryProvider(for provider: AIProvider, model: String) throws -> LLMProvider {
        let key = KeychainManager.shared.get(provider.keychainAccount) ?? ""
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }
        let resolvedModel = model.isEmpty ? provider.defaultModel : model
        guard !resolvedModel.isEmpty else {
            throw AppError.apiError(statusCode: 0, message: NSLocalizedString("error.no_model_selected", comment: "No model selected"))
        }
        switch provider.kind {
        case .openAICompatible:
            return OpenAIProvider(provider: provider, apiKey: key, model: resolvedModel)
        case .anthropic:
            return AnthropicProvider(provider: provider, apiKey: key, model: resolvedModel)
        case .googleGemini:
            return GoogleProvider(provider: provider, apiKey: key, model: resolvedModel)
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

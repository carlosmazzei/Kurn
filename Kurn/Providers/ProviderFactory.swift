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

    /// Build the cloud transcription (Whisper) provider chosen in Settings. Any
    /// OpenAI-compatible provider (OpenAI, Groq, or a custom endpoint) can serve
    /// the `/audio/transcriptions` route, so this resolves the selected provider's
    /// key and base URL independently of the summary provider. Throws `.noAPIKey`
    /// when the chosen provider has no stored key.
    static func whisperProvider(for provider: AIProvider, model: String) throws -> OpenAIProvider {
        let key = KeychainManager.shared.get(provider.keychainAccount) ?? ""
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }
        let resolvedModel = model.isEmpty ? provider.defaultTranscriptionModel : model
        // Background uploads: chunk transfers keep running when the app is
        // suspended or the phone is locked, so a long transcription doesn't
        // need the app to stay in the foreground.
        return OpenAIProvider(
            provider: provider,
            apiKey: key,
            transcriptionModel: resolvedModel,
            usesBackgroundUploads: true
        )
    }
}

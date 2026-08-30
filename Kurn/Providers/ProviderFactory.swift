//
//  ProviderFactory.swift
//  Kurn
//
//  Builds the correct `LLMProvider` from settings + keychain. Centralizes the
//  "do we have a key?" check so call sites get a clear `AppError.noAPIKey`.
//

import Foundation
import KurnCore

enum ProviderFactory {
    /// Build the summary provider chosen in Settings. Throws `.noAPIKey` when a
    /// cloud provider has no stored key, or `.onDeviceModelUnavailable` when the
    /// on-device provider is selected but `SystemLanguageModel` can't run —
    /// both fail the same way a missing dependency fails today, so every
    /// existing call site's error handling covers this with no changes.
    static func summaryProvider(for provider: AIProvider, model: String) throws -> LLMProvider {
        if provider.kind == .appleOnDevice {
            if let reason = OnDeviceModelAvailability.unavailableReason {
                AppLog.transcription.atError.error("ProviderFactory: on-device model unavailable (\(reason, privacy: .public))")
                throw AppError.onDeviceModelUnavailable(reason)
            }
            return FoundationModelsProvider(provider: provider)
        }

        guard LLMHTTP.isValidBaseURL(provider.baseURLString) else {
            throw AppError.invalidProviderURL
        }
        let key = KeychainManager.shared.get(provider.keychainAccount) ?? ""
        do {
            try LLMHTTP.requireAPIKey(key, provider: provider)
        } catch {
            AppLog.transcription.atError.error("ProviderFactory: missing API key for summary provider \(provider.displayName, privacy: .public)")
            throw error
        }
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
        case .appleOnDevice:
            preconditionFailure("handled above")
        }
    }

    /// Build the cloud transcription (Whisper) provider chosen in Settings. Any
    /// OpenAI-compatible provider (OpenAI, Groq, or a custom endpoint) can serve
    /// the `/audio/transcriptions` route, so this resolves the selected provider's
    /// key and base URL independently of the summary provider. Throws `.noAPIKey`
    /// when the chosen provider has no stored key.
    static func whisperProvider(for provider: AIProvider, model: String) throws -> OpenAIProvider {
        guard LLMHTTP.isValidBaseURL(provider.baseURLString) else {
            throw AppError.invalidProviderURL
        }
        let key = KeychainManager.shared.get(provider.keychainAccount) ?? ""
        do {
            try LLMHTTP.requireAPIKey(key, provider: provider)
        } catch {
            AppLog.transcription.atError.error("ProviderFactory: missing API key for transcription provider \(provider.displayName, privacy: .public)")
            throw error
        }
        let resolvedModel = model.isEmpty ? provider.defaultTranscriptionModel : model
        AppLog.transcription.atInfo.info("ProviderFactory: using \(provider.displayName, privacy: .public) for Whisper transcription, model=\(resolvedModel, privacy: .public)")
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

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
        let key = KeychainManager.shared.value(for: provider.keychainAccount) ?? ""
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
        case .elevenLabs:
            // Reachable only defensively — `configuredSummaryProviders`
            // already excludes transcription-only providers from the
            // summary-provider picker.
            throw AppError.summarizationUnsupported(provider: provider.displayName)
        case .appleOnDevice:
            preconditionFailure("handled above")
        }
    }

    /// Build the cloud transcription provider chosen in Settings. Any provider
    /// with `supportsTranscription` (OpenAI-compatible vendors via the Whisper
    /// route, or ElevenLabs via its own Scribe route) can serve this, resolved
    /// independently of the summary provider. Throws `.noAPIKey` when the
    /// chosen provider has no stored key.
    static func whisperProvider(
        for provider: AIProvider,
        model: String,
        transferPolicy: LargeTransferPolicy = .wifiOnly
    ) throws -> any LLMProvider {
        guard LLMHTTP.isValidBaseURL(provider.baseURLString) else {
            throw AppError.invalidProviderURL
        }
        let key = KeychainManager.shared.value(for: provider.keychainAccount) ?? ""
        do {
            try LLMHTTP.requireAPIKey(key, provider: provider)
        } catch {
            AppLog.transcription.atError.error("ProviderFactory: missing API key for transcription provider \(provider.displayName, privacy: .public)")
            throw error
        }
        let resolvedModel = model.isEmpty ? provider.defaultTranscriptionModel : model
        AppLog.transcription.atInfo.info("ProviderFactory: using \(provider.displayName, privacy: .public) for cloud transcription, model=\(resolvedModel, privacy: .public)")
        switch provider.kind {
        case .elevenLabs:
            return ElevenLabsProvider(
                provider: provider,
                apiKey: key,
                transcriptionModel: resolvedModel,
                largeTransferPolicy: transferPolicy
            )
        case .openAICompatible, .anthropic, .googleGemini, .appleOnDevice:
            // Reachable only defensively for anthropic/googleGemini/appleOnDevice —
            // `configuredTranscriptionProviders` already excludes them via
            // `supportsTranscription`.
            return OpenAIProvider(
                provider: provider,
                apiKey: key,
                transcriptionModel: resolvedModel,
                largeTransferPolicy: transferPolicy
            )
        }
    }
}

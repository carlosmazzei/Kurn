//
//  AppError.swift
//  KurnCore
//
//  Central error type surfaced to the UI via app dialogs or non-blocking banners.
//

import Foundation

/// All recoverable failures the app can produce. Conforms to `LocalizedError`
/// so UI presentation code can render a human-readable message directly.
public enum AppError: LocalizedError, Identifiable {
    case noAPIKey(provider: String)
    case networkError(URLError)
    case apiError(statusCode: Int, message: String)
    case invalidProviderURL
    case providerResponseTooLarge
    case ambiguousProviderResult
    case networkPolicyRestricted
    case transcriptionFailed(String)
    case transcriptionLanguageUnsupported(MeetingLanguage, TranscriptionEngine)
    case audioError(String)
    case decodingError(String)
    case permissionDenied(String)
    case persistenceFailed(String)
    case protectedStorageUnavailable(String)
    case modelDownloadRequired(String)
    case modelDownloadFailed(String)
    case resourceUnavailable(String)
    case authenticationRequired
    case authenticationFailed(String)
    case authenticationNotAvailable
    case autoTaggingFailed(String)
    case summaryTruncated
    case generationTruncated
    case logExportFailed(String)
    case embeddingUnavailable(String)
    case semanticIndexFailed(String)
    case wikiGenerationFailed(String)
    case wikiUnavailable
    case titleGenerationFailed(String)
    case documentGenerationFailed(String)
    case onDeviceModelUnavailable(String)
    /// A finished transcription run failed the final integrity gate (H5 PR
    /// 12) and was discarded before it could replace an existing transcript.
    /// The associated string is a closed-vocabulary `TranscriptIntegrityFailure`
    /// raw value, never free text.
    case transcriptIntegrityFailed(String)
    /// A Keychain read or write for a provider credential didn't simply
    /// succeed (H7 PR 14) — retryable, and never a sign the credential is
    /// missing. The associated string is a closed-vocabulary
    /// `KeychainFailureReason` raw value ("locked"/"denied"/"transient"),
    /// never a raw `OSStatus` or free text.
    case keychainAccessFailed(String)

    /// Stable identity for item-based presentation and comparisons.
    public var id: String { errorDescription ?? "AppError" }

    /// Content-free identifier safe to include in diagnostic logs. Provider
    /// messages and user data remain available to the UI but are never copied
    /// into this value.
    public var logCode: String {
        switch self {
        case .noAPIKey: return "missing_api_key"
        case .networkError: return "network"
        case .apiError: return "provider_api"
        case .invalidProviderURL: return "provider_configuration"
        case .providerResponseTooLarge: return "provider_response_too_large"
        case .ambiguousProviderResult: return "provider_result_ambiguous"
        case .networkPolicyRestricted: return "network_policy_restricted"
        case .transcriptionFailed: return "transcription"
        case .transcriptionLanguageUnsupported: return "transcription_language_unsupported"
        case .audioError: return "audio"
        case .decodingError: return "decoding"
        case .permissionDenied: return "permission"
        case .persistenceFailed: return "persistence"
        case .protectedStorageUnavailable: return "protected_storage"
        case .modelDownloadRequired: return "model_download_required"
        case .modelDownloadFailed: return "model_download"
        case .resourceUnavailable: return "resource"
        case .authenticationRequired: return "authentication_required"
        case .authenticationFailed: return "authentication"
        case .authenticationNotAvailable: return "authentication_unavailable"
        case .autoTaggingFailed: return "auto_tagging"
        case .summaryTruncated: return "summary_truncated"
        case .generationTruncated: return "generation_truncated"
        case .logExportFailed: return "log_export"
        case .embeddingUnavailable: return "embedding"
        case .semanticIndexFailed: return "semantic_index"
        case .wikiGenerationFailed: return "wiki_generation"
        case .wikiUnavailable: return "wiki_unavailable"
        case .titleGenerationFailed: return "title_generation"
        case .documentGenerationFailed: return "document_generation"
        case .onDeviceModelUnavailable: return "on_device_model_unavailable"
        case .transcriptIntegrityFailed: return "transcript_integrity"
        case .keychainAccessFailed: return "keychain_access"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noAPIKey(let provider):
            return String(
                format: NSLocalizedString("error.no_api_key", comment: "Missing API key"),
                provider
            )
        case .networkError(let urlError):
            return String(
                format: NSLocalizedString("error.network", comment: "Network failure"),
                urlError.localizedDescription
            )
        case .apiError(let statusCode, let message):
            return String(
                format: NSLocalizedString("error.api", comment: "API failure"),
                statusCode, message
            )
        case .invalidProviderURL:
            return NSLocalizedString(
                "error.invalid_provider_url",
                comment: "Provider URL is not allowed"
            )
        case .providerResponseTooLarge:
            return NSLocalizedString(
                "error.provider_response_too_large",
                comment: "Provider response exceeded the safe size limit"
            )
        case .ambiguousProviderResult:
            return NSLocalizedString(
                "error.ambiguous_provider_result",
                comment: "Provider result could not be confirmed without risking a duplicate"
            )
        case .networkPolicyRestricted:
            return NSLocalizedString(
                "error.network_policy_restricted",
                comment: "Large transfer blocked by the selected network policy"
            )
        case .transcriptionFailed(let detail):
            return String(
                format: NSLocalizedString("error.transcription", comment: "Transcription failure"),
                detail
            )
        case .transcriptionLanguageUnsupported(let language, let engine):
            return String(
                format: NSLocalizedString("error.transcription_language_unsupported", comment: "Transcription language unsupported"),
                language.displayName,
                engine.displayName
            )
        case .audioError(let detail):
            return String(
                format: NSLocalizedString("error.audio", comment: "Audio failure"),
                detail
            )
        case .decodingError(let detail):
            return String(
                format: NSLocalizedString("error.decoding", comment: "Decoding failure"),
                detail
            )
        case .permissionDenied(let detail):
            return String(
                format: NSLocalizedString("error.permission", comment: "Permission denied"),
                detail
            )
        case .persistenceFailed(let detail):
            return String(
                format: NSLocalizedString("error.persistence", comment: "Save failure"),
                detail
            )
        case .protectedStorageUnavailable(let detail):
            return String(
                format: NSLocalizedString("error.protected_storage", comment: "Protected storage unavailable"),
                detail
            )
        case .modelDownloadRequired(let detail):
            return String(
                format: NSLocalizedString("error.model_download_required", comment: "Model download required"),
                detail
            )
        case .modelDownloadFailed(let detail):
            return String(
                format: NSLocalizedString("error.model_download_failed", comment: "Model download failed"),
                detail
            )
        case .resourceUnavailable(let detail):
            return String(
                format: NSLocalizedString("error.resource_unavailable", comment: "Resource unavailable"),
                detail
            )
        case .authenticationRequired:
            return NSLocalizedString(
                "error.authentication_required",
                comment: "Authentication required to access recordings"
            )
        case .authenticationFailed(let detail):
            return String(
                format: NSLocalizedString("error.authentication_failed", comment: "Authentication failed"),
                detail
            )
        case .authenticationNotAvailable:
            return NSLocalizedString(
                "error.authentication_not_available",
                comment: "Device has no passcode or biometrics configured"
            )
        case .autoTaggingFailed(let detail):
            return String(
                format: NSLocalizedString("error.auto_tagging", comment: "Auto-tagging failed"),
                detail
            )
        case .summaryTruncated:
            return NSLocalizedString(
                "error.summary_truncated",
                comment: "Summary generation hit the model's output limit"
            )
        case .generationTruncated:
            return NSLocalizedString(
                "error.generation_truncated",
                comment: "Text generation hit the model's output limit"
            )
        case .logExportFailed(let detail):
            return String(
                format: NSLocalizedString("error.log_export", comment: "Log export failure"),
                detail
            )
        case .embeddingUnavailable(let detail):
            return String(
                format: NSLocalizedString("error.embedding_unavailable", comment: "Embedding model unavailable"),
                detail
            )
        case .semanticIndexFailed(let detail):
            return String(
                format: NSLocalizedString("error.semantic_index", comment: "Semantic indexing failed"),
                detail
            )
        case .wikiGenerationFailed(let detail):
            return String(
                format: NSLocalizedString("error.wiki_generation", comment: "Wiki generation failed"),
                detail
            )
        case .wikiUnavailable:
            return NSLocalizedString(
                "error.wiki_unavailable",
                comment: "Meeting wiki is not ready yet"
            )
        case .titleGenerationFailed(let detail):
            return String(
                format: NSLocalizedString("error.title_generation", comment: "AI title generation failed"),
                detail
            )
        case .documentGenerationFailed(let detail):
            return String(
                format: NSLocalizedString("error.document_generation", comment: "Document generation failed"),
                detail
            )
        case .onDeviceModelUnavailable(let detail):
            return String(
                format: NSLocalizedString("error.on_device_model_unavailable", comment: "On-device model unavailable"),
                detail
            )
        case .transcriptIntegrityFailed(let reason):
            return String(
                format: NSLocalizedString("error.transcript_integrity_failed", comment: "Transcript failed its integrity check"),
                reason
            )
        case .keychainAccessFailed(let reason):
            return String(
                format: NSLocalizedString("error.keychain_access_failed", comment: "Keychain access failed"),
                reason
            )
        }
    }
}

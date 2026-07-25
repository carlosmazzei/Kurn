//
//  AppError.swift
//  Kurn
//
//  Central error type surfaced to the UI via app dialogs or non-blocking banners.
//

import Foundation

/// All recoverable failures the app can produce. Conforms to `LocalizedError`
/// so UI presentation code can render a human-readable message directly.
enum AppError: LocalizedError, Identifiable {
    case noAPIKey(provider: String)
    case networkError(URLError)
    case apiError(statusCode: Int, message: String)
    case transcriptionFailed(String)
    case audioError(String)
    case decodingError(String)
    case permissionDenied(String)
    case persistenceFailed(String)
    case modelDownloadRequired(String)
    case modelDownloadFailed(String)
    case resourceUnavailable(String)
    case authenticationRequired
    case authenticationFailed(String)
    case authenticationNotAvailable
    case autoTaggingFailed(String)
    case summaryTruncated
    case logExportFailed(String)
    case embeddingUnavailable(String)
    case semanticIndexFailed(String)
    case wikiGenerationFailed(String)
    case wikiUnavailable

    /// Stable identity for item-based presentation and comparisons.
    var id: String { errorDescription ?? "AppError" }

    var errorDescription: String? {
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
        case .transcriptionFailed(let detail):
            return String(
                format: NSLocalizedString("error.transcription", comment: "Transcription failure"),
                detail
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
        }
    }
}

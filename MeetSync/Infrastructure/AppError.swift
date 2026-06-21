//
//  AppError.swift
//  MeetSync
//
//  Central error type surfaced to the UI via alerts or non-blocking banners.
//

import Foundation

/// All recoverable failures the app can produce. Conforms to `LocalizedError`
/// so SwiftUI `.alert` modifiers can render a human-readable message directly.
enum AppError: LocalizedError, Identifiable {
    case noAPIKey(provider: String)
    case networkError(URLError)
    case apiError(statusCode: Int, message: String)
    case transcriptionFailed(String)
    case audioError(String)
    case decodingError(String)
    case permissionDenied(String)
    case persistenceFailed(String)

    /// Stable identity so the value can drive `.alert(item:)`.
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
        }
    }
}

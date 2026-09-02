//
//  AppErrorMetadata.swift
//  KurnCore
//
//  H9 PR 21: presentation metadata around `AppError`, extracted from
//  `AppError.swift` to keep that file to its own concerns (case list plus
//  `logCode`/`errorDescription`) as this grows. None of this is new UI —
//  wiring `recoveryAction` into actual contextual buttons (Retry, Free Space,
//  Open Settings, ...) is H9 item 2, a later PR; this only names, per case,
//  which single action would apply, so that PR has something to switch on
//  instead of re-deriving it from scratch.
//

import Foundation

/// Coarse grouping for routing/metrics — never shown to the user directly
/// (`errorDescription` is the localized, user-facing text).
public enum AppErrorCategory: String, Sendable {
    case network
    case provider
    case transcription
    case audio
    case storage
    case permission
    case authentication
    case resource
    case model
    case generation
    case integrity
}

/// Whether an error must interrupt the operation it belongs to until the
/// user acts, or can be recorded and shown without blocking anything else —
/// H9 item 3's "queue blocking errors per operation and retain warnings in
/// operation reports": severity is what a caller checks to decide which of
/// the two an error becomes.
public enum AppErrorSeverity: String, Sendable {
    case blocking
    case warning
}

/// A stable identifier for the single most relevant next step, when one
/// applies. Not every error has one.
public enum AppErrorRecoveryAction: String, Sendable {
    case retry
    case openSettings
    case freeSpace
    case changeProviderOrModel
    case recoverQuarantinedAudio
    case exportDiagnostics
}

extension AppError {
    /// Coarse category for this error.
    public var category: AppErrorCategory {
        switch self {
        case .networkError, .networkPolicyRestricted:
            return .network
        case .noAPIKey, .apiError, .invalidProviderURL, .providerResponseTooLarge,
             .ambiguousProviderResult:
            return .provider
        case .transcriptionFailed, .transcriptionLanguageUnsupported:
            return .transcription
        case .audioError:
            return .audio
        case .decodingError, .persistenceFailed, .protectedStorageUnavailable, .logExportFailed:
            return .storage
        case .permissionDenied:
            return .permission
        case .authenticationRequired, .authenticationFailed, .authenticationNotAvailable, .keychainAccessFailed:
            return .authentication
        case .resourceUnavailable:
            return .resource
        case .modelDownloadRequired, .modelDownloadFailed, .embeddingUnavailable, .onDeviceModelUnavailable:
            return .model
        case .autoTaggingFailed, .summaryTruncated, .generationTruncated, .semanticIndexFailed,
             .wikiGenerationFailed, .wikiUnavailable, .documentGenerationFailed:
            return .generation
        case .transcriptIntegrityFailed:
            return .integrity
        }
    }

    /// Whether this error should block the operation it belongs to (queued,
    /// interrupting) or only be retained as a non-blocking warning.
    public var severity: AppErrorSeverity {
        switch self {
        case .decodingError, .resourceUnavailable, .autoTaggingFailed, .summaryTruncated,
             .generationTruncated, .logExportFailed, .embeddingUnavailable, .semanticIndexFailed,
             .wikiGenerationFailed, .wikiUnavailable:
            return .warning
        default:
            return .blocking
        }
    }

    /// Whether retrying the same operation is a reasonable next step. This is
    /// a per-case default, not a live judgment of the failure's actual cause
    /// (e.g. `.apiError`'s automatic transport retry, `LLMHTTP.sendValidated`,
    /// already exhausted its own budget before this ever reaches the UI — a
    /// manual retry here is still meaningful, it just starts a fresh attempt
    /// rather than resuming the exhausted one).
    public var isRetryable: Bool {
        switch self {
        case .networkError, .apiError, .ambiguousProviderResult, .transcriptionFailed,
             .persistenceFailed, .modelDownloadFailed, .resourceUnavailable, .authenticationFailed,
             .autoTaggingFailed, .logExportFailed, .semanticIndexFailed, .wikiGenerationFailed,
             .documentGenerationFailed, .transcriptIntegrityFailed, .keychainAccessFailed:
            return true
        default:
            return false
        }
    }

    /// The single most relevant recovery action, if any. `nil` when no
    /// generic action applies (e.g. the error is already the terminal state
    /// of a best-effort background step).
    public var recoveryAction: AppErrorRecoveryAction? {
        switch self {
        case .networkError, .apiError, .ambiguousProviderResult, .transcriptionFailed,
             .persistenceFailed, .modelDownloadFailed, .authenticationFailed, .autoTaggingFailed,
             .logExportFailed, .semanticIndexFailed, .wikiGenerationFailed,
             .documentGenerationFailed, .transcriptIntegrityFailed, .keychainAccessFailed:
            return .retry
        case .noAPIKey, .invalidProviderURL, .networkPolicyRestricted, .permissionDenied,
             .authenticationNotAvailable:
            return .openSettings
        case .resourceUnavailable:
            return .freeSpace
        case .transcriptionLanguageUnsupported:
            return .changeProviderOrModel
        default:
            return nil
        }
    }

    /// Diagnostic detail beyond the safe, localized `errorDescription` — the
    /// raw associated string a handful of cases carry (typically another
    /// error's own `localizedDescription`, e.g. from SwiftData or
    /// `AVFoundation`). `nil` for every case with no such detail. This is
    /// deliberately *not* wired into any export or log path yet — H9 item 6
    /// ("redaction preview", PR 22) owns deciding how it may leave the
    /// device; this only names the field so that PR has something to read
    /// instead of re-deriving it from `errorDescription`'s interpolation.
    public var privateContext: String? {
        switch self {
        case .apiError(_, let message):
            return message
        case .transcriptionFailed(let detail),
             .audioError(let detail),
             .decodingError(let detail),
             .persistenceFailed(let detail),
             .protectedStorageUnavailable(let detail),
             .modelDownloadRequired(let detail),
             .modelDownloadFailed(let detail),
             .resourceUnavailable(let detail),
             .authenticationFailed(let detail),
             .autoTaggingFailed(let detail),
             .logExportFailed(let detail),
             .embeddingUnavailable(let detail),
             .semanticIndexFailed(let detail),
             .wikiGenerationFailed(let detail),
             .documentGenerationFailed(let detail),
             .onDeviceModelUnavailable(let detail):
            return detail
        case .networkError(let urlError):
            return urlError.localizedDescription
        default:
            return nil
        }
    }
}

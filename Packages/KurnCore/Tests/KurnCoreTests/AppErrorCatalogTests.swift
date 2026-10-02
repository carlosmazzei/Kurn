//
//  AppErrorCatalogTests.swift
//  KurnCoreTests
//
//  Every `AppError` case, walked through every derived property. The
//  per-case judgment calls live in `AppErrorMetadataTests`; this suite pins
//  the properties that must hold for *all* cases — a content-free, unique
//  `logCode`, a description for every case, private context that only ever
//  carries the case's own detail, and retryable errors that offer a way to
//  retry. Messages are localized in the app bundle, so on Linux
//  `errorDescription` is the localization key; the assertions only rely on
//  it being present.
//

import Foundation
import Testing
@testable import KurnCore

struct AppErrorCatalogTests {
    private static let detail = "private-detail-7f3a"

    /// One value per case. Adding a case to `AppError` without adding it
    /// here fails `catalogCoversEveryLogCode`.
    private static let allCases: [AppError] = [
        .noAPIKey(provider: detail),
        .networkError(URLError(.notConnectedToInternet)),
        .apiError(statusCode: 500, message: detail),
        .invalidProviderURL,
        .providerResponseTooLarge,
        .ambiguousProviderResult,
        .networkPolicyRestricted,
        .transcriptionFailed(detail),
        .transcriptionLanguageUnsupported(.portuguese, .appleSpeech),
        .audioError(detail),
        .decodingError(detail),
        .permissionDenied(detail),
        .persistenceFailed(detail),
        .protectedStorageUnavailable(detail),
        .modelDownloadRequired(detail),
        .modelDownloadFailed(detail),
        .resourceUnavailable(detail),
        .authenticationRequired,
        .authenticationFailed(detail),
        .authenticationNotAvailable,
        .autoTaggingFailed(detail),
        .summaryTruncated,
        .generationTruncated,
        .logExportFailed(detail),
        .embeddingUnavailable(detail),
        .semanticIndexFailed(detail),
        .wikiGenerationFailed(detail),
        .wikiUnavailable,
        .titleGenerationFailed(detail),
        .documentGenerationFailed(detail),
        .summaryTranslationFailed(detail),
        .onDeviceModelUnavailable(detail),
        .transcriptIntegrityFailed("empty_transcript"),
        .keychainAccessFailed("locked"),
        .summarizationUnsupported(provider: detail),
        .speechSynthesisFailed(detail)
    ]

    @Test func catalogCoversEveryLogCode() {
        let codes = Self.allCases.map(\.logCode)
        #expect(Set(codes).count == codes.count, "every case has its own log code")
        #expect(codes.count == 36)
    }

    @Test func logCodesAreClosedVocabularyAndNeverCarryDetail() {
        for error in Self.allCases {
            let code = error.logCode
            #expect(!code.isEmpty)
            #expect(code.allSatisfy { $0.isLowercase || $0 == "_" }, "\(code) is snake_case")
            #expect(!code.contains(Self.detail))
        }
    }

    @Test func everyCaseHasADescriptionAndAStableID() {
        for error in Self.allCases {
            let description = error.errorDescription
            #expect(description?.isEmpty == false, "\(error.logCode) has a description")
            #expect(error.id == description)
        }
    }

    @Test func retryableErrorsOfferARetryOrAFreeSpaceAction() {
        for error in Self.allCases where error.isRetryable {
            let action = error.recoveryAction
            #expect(action == .retry || action == .freeSpace, "\(error.logCode) can be retried from the UI")
        }
        #expect(AppError.resourceUnavailable(Self.detail).recoveryAction == .freeSpace)
    }

    @Test func nonRetryableErrorsNeverOfferARetry() {
        for error in Self.allCases where !error.isRetryable {
            #expect(error.recoveryAction != .retry, "\(error.logCode) must not offer a retry")
        }
    }

    @Test func settingsAndProviderActionsMatchTheirCases() {
        #expect(AppError.noAPIKey(provider: "x").recoveryAction == .openSettings)
        #expect(AppError.permissionDenied("x").recoveryAction == .openSettings)
        #expect(AppError.authenticationNotAvailable.recoveryAction == .openSettings)
        #expect(AppError.summarizationUnsupported(provider: "x").recoveryAction == .changeProviderOrModel)
        #expect(AppError.transcriptionLanguageUnsupported(.english, .whisperCpp).recoveryAction == .changeProviderOrModel)
        #expect(AppError.wikiUnavailable.recoveryAction == nil)
        #expect(AppError.summaryTruncated.recoveryAction == nil)
    }

    @Test func everyCaseHasACategoryAndSeverity() {
        let categories = Set(Self.allCases.map(\.category))
        #expect(categories.count == 11, "every category is reachable")
        let severities = Set(Self.allCases.map(\.severity))
        #expect(severities == [.blocking, .warning])
    }

    @Test func privateContextIsOnlyTheCaseOwnDetail() {
        for error in Self.allCases {
            guard let context = error.privateContext else { continue }
            if case .networkError = error {
                #expect(!context.isEmpty)
            } else {
                #expect(context == Self.detail, "\(error.logCode) exposes only its own detail")
            }
        }
    }

    @Test func casesWithoutDetailCarryNoPrivateContext() {
        #expect(AppError.invalidProviderURL.privateContext == nil)
        #expect(AppError.noAPIKey(provider: "OpenAI").privateContext == nil)
        #expect(AppError.permissionDenied("microphone").privateContext == nil)
        #expect(AppError.keychainAccessFailed("locked").privateContext == nil)
        #expect(AppError.networkError(URLError(.timedOut)).privateContext != nil)
    }
}

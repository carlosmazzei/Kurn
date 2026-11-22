//
//  ErrorRecoveryTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ErrorRecoveryTests {
    @Test func retryNeedsACallerThatCanRerun() {
        let error = AppError.networkError(URLError(.timedOut))
        #expect(ErrorRecovery(error: error, canRetry: false) == nil)
        #expect(ErrorRecovery(error: error, canRetry: true)?.destination == .retry)
    }

    @Test func settingsErrorsOpenTheScreenThatFixesThem() {
        #expect(ErrorRecovery(error: .noAPIKey(provider: "x"), canRetry: false)?.destination == .screen(.providers))
        #expect(ErrorRecovery(error: .invalidProviderURL, canRetry: false)?.destination == .screen(.providers))
        #expect(ErrorRecovery(error: .permissionDenied("x"), canRetry: false)?.destination == .screen(.transcription))
        // A refused iOS speech permission can only be granted again in the
        // system Settings app, not in the app's Transcription screen.
        #expect(ErrorRecovery(error: .speechRecognitionDenied, canRetry: false)?.destination == .systemSettings)
        #expect(ErrorRecovery(error: .authenticationNotAvailable, canRetry: false)?.destination == .systemSettings)
    }

    @Test func storageAndModelErrorsOpenTheirSettings() {
        #expect(ErrorRecovery(error: .resourceUnavailable("x"), canRetry: false)?.destination == .screen(.storage))
        #expect(ErrorRecovery(error: .summarizationUnsupported(provider: "x"), canRetry: false)?.destination == .screen(.summary))
        #expect(ErrorRecovery(error: .transcriptionLanguageUnsupported(.english, .whisperCpp), canRetry: false)?
            .destination == .screen(.transcription))
    }

    @Test func errorsWithoutAnActionOfferOnlyOK() {
        #expect(ErrorRecovery(error: .networkPolicyRestricted, canRetry: true) == nil)
        #expect(ErrorRecovery(error: .wikiUnavailable, canRetry: true) == nil)
        #expect(ErrorRecovery(error: .summaryTruncated, canRetry: true) == nil)
    }

    @Test func everyActionHasALocalizedTitle() {
        let errors: [AppError] = [
            .networkError(URLError(.timedOut)), .noAPIKey(provider: "x"), .resourceUnavailable("x"),
            .summarizationUnsupported(provider: "x")
        ]
        for error in errors {
            let title = ErrorRecovery(error: error, canRetry: true)?.title
            #expect(title?.isEmpty == false)
            #expect(title?.hasPrefix("error.recovery.") == false, "\(error.logCode) has a translation")
        }
    }
}

extension ErrorRecoveryTests {
    @Test func deferredWikiReasonsMapToTheScreenThatFixesThem() {
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "provider_unavailable"), canRetry: false)?
            .destination == .screen(.providers))
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "policy_denied"), canRetry: false)?
            .destination == .screen(.privacy))
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "cloud_review_required"), canRetry: false)?
            .destination == .screen(.privacy))
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "knowledge_paused"), canRetry: false)?
            .destination == .screen(.knowledge))
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "knowledge_automatic_disabled"), canRetry: false)?
            .destination == .screen(.knowledge))
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "feature_disabled"), canRetry: false)?
            .destination == .screen(.knowledge))
    }

    @Test func retryableDeferredReasonsOfferRetry() {
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "provider_blocked"), canRetry: true)?
            .destination == .retry)
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "last_attempt_failed"), canRetry: true)?
            .destination == .retry)
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "recording"), canRetry: true)?
            .destination == .retry)
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "provider_blocked"), canRetry: false) == nil)
    }

    @Test func deferredReasonsWithoutAFixOfferOnlyOK() {
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "no_transcript"), canRetry: true) == nil)
        #expect(ErrorRecovery(error: .wikiGenerationDeferred(reason: "something_new"), canRetry: true) == nil)
        // Every deferred description must be a non-empty localized string.
        for reason in ["feature_disabled", "provider_unavailable", "provider_blocked", "policy_denied",
                       "cloud_review_required", "knowledge_paused", "knowledge_automatic_disabled",
                       "background", "recording", "no_transcript", "last_attempt_failed", "unknown_code"] {
            let description = AppError.wikiGenerationDeferred(reason: reason).errorDescription
            #expect(description?.isEmpty == false)
        }
    }
}

//
//  AppErrorMetadataTests.swift
//  KurnCoreTests
//
//  H9 PR 21: `category` is the one property with no `default` case, so a
//  future `AppError` case that's added without a matching `category` arm
//  fails to compile — these tests instead pin the judgment calls that
//  *aren't* compiler-enforced: severity (blocking vs. warning), retryability,
//  the recovery action, and which cases carry private diagnostic context.
//

import Foundation
import Testing
@testable import KurnCore

struct AppErrorMetadataTests {

    // MARK: - Category

    @Test func authenticationFailedIsCategorizedAsAuthenticationNotProvider() {
        // `.authenticationFailed` comes from `RecordingAccessGate` (Face ID/
        // Touch ID/passcode), not a cloud provider — the two are easy to
        // conflate by name alone.
        #expect(AppError.authenticationFailed("test").category == .authentication)
    }

    @Test func providerErrorsAreCategorizedAsProvider() {
        #expect(AppError.noAPIKey(provider: "OpenAI").category == .provider)
        #expect(AppError.apiError(statusCode: 500, message: "boom").category == .provider)
        #expect(AppError.invalidProviderURL.category == .provider)
    }

    // MARK: - Severity

    @Test func bestEffortPostTranscriptionFailuresAreWarnings() {
        // These are the "each step is best-effort and exposes its own
        // state; failures never mutate transcription status" cases from
        // `TranscriptionViewModel.startPostTranscriptionWork` — they must
        // never block the operation they're attached to.
        #expect(AppError.autoTaggingFailed("x").severity == .warning)
        #expect(AppError.semanticIndexFailed("x").severity == .warning)
        #expect(AppError.wikiGenerationFailed("x").severity == .warning)
        #expect(AppError.summaryTruncated.severity == .warning)
    }

    @Test func coreFailuresAreBlocking() {
        #expect(AppError.transcriptionFailed("x").severity == .blocking)
        #expect(AppError.persistenceFailed("x").severity == .blocking)
        #expect(AppError.noAPIKey(provider: "OpenAI").severity == .blocking)
    }

    // MARK: - Retryability

    @Test func transientFailuresAreRetryable() {
        #expect(AppError.networkError(URLError(.notConnectedToInternet)).isRetryable)
        #expect(AppError.apiError(statusCode: 503, message: "x").isRetryable)
        #expect(AppError.persistenceFailed("x").isRetryable)
    }

    @Test func configurationFailuresAreNotRetryable() {
        // Retrying an unchanged missing API key or an unsupported
        // language/engine pairing would just fail again identically.
        #expect(!AppError.noAPIKey(provider: "OpenAI").isRetryable)
        #expect(!AppError.transcriptionLanguageUnsupported(.portuguese, .appleSpeech).isRetryable)
    }

    // MARK: - Recovery action

    @Test func missingConfigurationRecoversByOpeningSettings() {
        #expect(AppError.noAPIKey(provider: "OpenAI").recoveryAction == .openSettings)
        #expect(AppError.permissionDenied("mic").recoveryAction == .openSettings)
        #expect(AppError.networkPolicyRestricted.recoveryAction == .openSettings)
    }

    @Test func resourceUnavailableRecoversByFreeingSpace() {
        #expect(AppError.resourceUnavailable("disk").recoveryAction == .freeSpace)
    }

    @Test func unsupportedLanguageRecoversByChangingProviderOrModel() {
        #expect(AppError.transcriptionLanguageUnsupported(.portuguese, .appleSpeech).recoveryAction == .changeProviderOrModel)
    }

    @Test func terminalBestEffortOutcomesHaveNoRecoveryAction() {
        #expect(AppError.summaryTruncated.recoveryAction == nil)
        #expect(AppError.wikiUnavailable.recoveryAction == nil)
    }

    // MARK: - Private context

    @Test func casesWithAnUnderlyingDetailExposeItAsPrivateContext() {
        #expect(AppError.transcriptionFailed("underlying detail").privateContext == "underlying detail")
        #expect(AppError.apiError(statusCode: 500, message: "server said this").privateContext == "server said this")
        let urlError = URLError(.timedOut)
        #expect(AppError.networkError(urlError).privateContext == urlError.localizedDescription)
    }

    @Test func casesWithNoUnderlyingDetailHaveNoPrivateContext() {
        #expect(AppError.wikiUnavailable.privateContext == nil)
        #expect(AppError.authenticationRequired.privateContext == nil)
        #expect(AppError.summaryTruncated.privateContext == nil)
    }
}

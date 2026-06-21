//
//  AppErrorTests.swift
//  MeetSyncTests
//

import Foundation
import Testing
@testable import MeetSync

struct AppErrorTests {

    @Test func idIsDerivedFromErrorDescription() {
        let error = AppError.audioError("disk full")
        #expect(error.id == error.errorDescription)
    }

    @Test func noAPIKeyMessageIncludesProviderName() {
        let error = AppError.noAPIKey(provider: "Anthropic")
        #expect(error.errorDescription?.contains("Anthropic") == true)
    }

    @Test func apiErrorMessageIncludesStatusCodeAndMessage() {
        let error = AppError.apiError(statusCode: 429, message: "rate limited")
        let description = error.errorDescription ?? ""
        #expect(description.contains("429"))
        #expect(description.contains("rate limited"))
    }

    @Test func everyCaseProducesNonEmptyDescription() {
        let cases: [AppError] = [
            .noAPIKey(provider: "OpenAI"),
            .networkError(URLError(.notConnectedToInternet)),
            .apiError(statusCode: 500, message: "boom"),
            .transcriptionFailed("bad audio"),
            .audioError("mic busy"),
            .decodingError("bad json"),
            .permissionDenied("speech"),
            .persistenceFailed("disk full"),
        ]
        for error in cases {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }
}

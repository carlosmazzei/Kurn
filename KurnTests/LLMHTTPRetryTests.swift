//
//  LLMHTTPRetryTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct LLMHTTPRetryTests {

    // MARK: - Retriable vs. non-retriable

    @Test func transientStatusCodesAreRetried() {
        for status in [408, 429, 500, 502, 503, 504] {
            let delay = LLMHTTP.retryableDelay(attempt: 0, status: status, urlError: nil, retryAfter: nil)
            #expect(delay != nil, "status \(status) should be retriable")
        }
    }

    @Test func clientErrorsAreNotRetried() {
        for status in [400, 401, 403, 404] {
            let delay = LLMHTTP.retryableDelay(attempt: 0, status: status, urlError: nil, retryAfter: nil)
            #expect(delay == nil, "status \(status) should not be retriable")
        }
    }

    @Test func transientURLErrorsAreRetried() {
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .notConnectedToInternet, .dnsLookupFailed
        ]
        for code in codes {
            let delay = LLMHTTP.retryableDelay(
                attempt: 0, status: nil, urlError: URLError(code), retryAfter: nil
            )
            #expect(delay != nil, "URLError \(code.rawValue) should be retriable")
        }
    }

    @Test func nonTransientURLErrorIsNotRetried() {
        let delay = LLMHTTP.retryableDelay(
            attempt: 0, status: nil, urlError: URLError(.badURL), retryAfter: nil
        )
        #expect(delay == nil)
    }

    @Test func successAndUnknownFailuresAreNotRetried() {
        // No status and no URLError → nothing to retry on.
        #expect(LLMHTTP.retryableDelay(attempt: 0, status: nil, urlError: nil, retryAfter: nil) == nil)
        #expect(LLMHTTP.retryableDelay(attempt: 0, status: 200, urlError: nil, retryAfter: nil) == nil)
    }

    // MARK: - Budget

    @Test func attemptsAreCappedByMaxAttempts() {
        // The last attempt (index maxAttempts - 1) must not schedule another retry.
        let lastIndex = LLMHTTP.maxAttempts - 1
        #expect(LLMHTTP.retryableDelay(attempt: lastIndex, status: 503, urlError: nil, retryAfter: nil) == nil)
        // Any earlier attempt on a transient failure does.
        #expect(LLMHTTP.retryableDelay(attempt: lastIndex - 1, status: 503, urlError: nil, retryAfter: nil) != nil)
    }

    // MARK: - Backoff shape

    @Test func backoffStaysWithinExpectedBounds() throws {
        // Delay = base * 2^attempt + jitter(0...base), clamped to maxDelay.
        for attempt in 0..<(LLMHTTP.maxAttempts - 1) {
            let exponential = LLMHTTP.baseDelay * pow(2, Double(attempt))
            let delay = try #require(
                LLMHTTP.retryableDelay(attempt: attempt, status: 500, urlError: nil, retryAfter: nil)
            )
            #expect(delay >= exponential)
            #expect(delay <= min(exponential + LLMHTTP.baseDelay, LLMHTTP.maxDelay))
        }
    }

    @Test func retryAfterHeaderIsHonoredForRateLimiting() {
        // A server Retry-After overrides the computed backoff (clamped to maxDelay).
        let delay = LLMHTTP.retryableDelay(attempt: 0, status: 429, urlError: nil, retryAfter: 2)
        #expect(delay == 2)
    }

    @Test func retryAfterIsClampedToMaxDelay() {
        let delay = LLMHTTP.retryableDelay(
            attempt: 0, status: 503, urlError: nil, retryAfter: LLMHTTP.maxDelay + 100
        )
        #expect(delay == LLMHTTP.maxDelay)
    }
}

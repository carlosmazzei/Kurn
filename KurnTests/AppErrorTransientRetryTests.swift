import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// NH07: which provider failures the agent session may retry.
struct AppErrorTransientRetryTests {
    @Test(arguments: [408, 429, 500, 502, 503, 504])
    func transientStatusesAreRetried(status: Int) {
        let error = AppError.apiError(statusCode: status, message: "busy")
        #expect(error.isTransient)
        #expect(error.retryAfterSeconds == nil)
        #expect(AgentRetryPolicy.standard.delay(after: error, failedAttempts: 1, waited: 0) != nil)
    }

    @Test func otherFailuresAreNot() {
        let permanent: [AppError] = [
            .apiError(statusCode: 400, message: "bad"), .apiError(statusCode: 401, message: "auth"),
            .apiError(statusCode: 413, message: "too long"), .apiError(statusCode: 0, message: "remote"),
            .noAPIKey(provider: "OpenAI"), .decodingError("invalid"),
            // The provider may already be generating for a timeout or a lost connection.
            .networkError(URLError(.timedOut)), .networkError(URLError(.networkConnectionLost)),
            .networkError(URLError(.cancelled))
        ]
        for error in permanent { #expect(!error.isTransient) }
        #expect(AppError.networkError(URLError(.cannotConnectToHost)).isTransient)
        #expect(AppError.networkError(URLError(.notConnectedToInternet)).isTransient)
    }
}

import Foundation

/// A failure a model request may be retried after (NH07): rate limiting, a transient server
/// error or a connection that never opened. Hosts conform their own error types; anything that
/// does not conform — authentication, configuration, quota, context overflow, invalid tool
/// arguments, cancellation — is never retried by the session.
public protocol AgentTransientError: Error {
    /// Whether the request can be sent again unchanged.
    var isTransient: Bool { get }
    /// The provider's own `Retry-After`, in seconds, when it gave one.
    var retryAfterSeconds: Double? { get }
}

/// How the session retries a model request that failed before it produced anything (NH07). The
/// harness is the one retry owner for its requests: hosts keep transport retries off for them.
/// Each attempt is its own request with its own identity, its failure is recorded as audit data,
/// and a request that already streamed visible text is never retried — two generations are never
/// joined. The wait honours the provider's `Retry-After`, is bounded by `maxDelaySeconds` and by
/// the total `maxWaitSeconds`, and is cancellable: cancelling during it starts no new attempt.
public struct AgentRetryPolicy: Sendable {
    /// Total attempts per request, the first included; 1 never retries.
    public let maxAttempts: Int
    public let baseDelaySeconds: Double
    public let maxDelaySeconds: Double
    /// The most a request may wait across all its retries.
    public let maxWaitSeconds: Double
    let sleep: @Sendable (Double) async throws -> Void

    public init(maxAttempts: Int, baseDelaySeconds: Double = 1, maxDelaySeconds: Double = 20,
                maxWaitSeconds: Double = 45,
                sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelaySeconds = max(0, baseDelaySeconds)
        self.maxDelaySeconds = max(0, maxDelaySeconds)
        self.maxWaitSeconds = max(0, maxWaitSeconds)
        self.sleep = sleep
    }

    /// No retries: the first failure is the request's failure.
    public static let none = AgentRetryPolicy(maxAttempts: 1)
    /// Three attempts, with exponential backoff from one second.
    public static let standard = AgentRetryPolicy(maxAttempts: 3)

    /// The wait before attempt `failedAttempts + 1`, or nil when `error` must not be retried:
    /// not transient, attempts exhausted, a `Retry-After` beyond `maxDelaySeconds`, or a wait
    /// that would pass `maxWaitSeconds` given `waited` so far.
    public func delay(after error: Error, failedAttempts: Int, waited: Double) -> Double? {
        guard failedAttempts < maxAttempts, let transient = error as? any AgentTransientError,
              transient.isTransient else { return nil }
        let delay: Double
        if let retryAfter = transient.retryAfterSeconds {
            guard retryAfter <= maxDelaySeconds else { return nil }
            delay = max(0, retryAfter)
        } else {
            delay = min(maxDelaySeconds, baseDelaySeconds * pow(2, Double(failedAttempts - 1)))
        }
        return waited + delay <= maxWaitSeconds ? delay : nil
    }
}

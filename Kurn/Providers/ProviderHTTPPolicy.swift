//
//  ProviderHTTPPolicy.swift
//  Kurn
//

import Foundation

enum HTTPReplaySafety: Equatable, Sendable {
    case idempotent
    case ambiguous
}

struct HTTPRequestSemantics: Sendable {
    let identity: UUID
    let replaySafety: HTTPReplaySafety
    let correlationHeaderName: String?

    init(
        identity: UUID = UUID(),
        replaySafety: HTTPReplaySafety,
        correlationHeaderName: String? = nil
    ) {
        self.identity = identity
        self.replaySafety = replaySafety
        self.correlationHeaderName = correlationHeaderName
    }

    static func inferred(for request: URLRequest) -> Self {
        let idempotentMethods = ["GET", "HEAD", "OPTIONS"]
        let method = request.httpMethod?.uppercased() ?? "GET"
        return Self(
            replaySafety: idempotentMethods.contains(method) ? .idempotent : .ambiguous
        )
    }

    func applying(to request: URLRequest) -> URLRequest {
        guard let correlationHeaderName else { return request }
        var request = request
        request.setValue(identity.uuidString, forHTTPHeaderField: correlationHeaderName)
        return request
    }
}

struct HTTPExecutionContext: Sendable {
    let semantics: HTTPRequestSemantics
    let wallNow: @Sendable () -> Date

    init(
        semantics: HTTPRequestSemantics,
        wallNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.semantics = semantics
        self.wallNow = wallNow
    }

    static func inferred(for request: URLRequest) -> Self {
        Self(semantics: .inferred(for: request))
    }
}

struct HTTPPolicy: Equatable, Sendable {
    static let defaultMaxResponseBytes = 16 * 1_024 * 1_024

    let totalDeadline: TimeInterval
    let maxResponseBytes: Int
    let maximumServerWait: TimeInterval

    init(
        totalDeadline: TimeInterval,
        maxResponseBytes: Int = defaultMaxResponseBytes,
        maximumServerWait: TimeInterval = 30
    ) {
        self.totalDeadline = max(0, totalDeadline)
        self.maxResponseBytes = max(0, maxResponseBytes)
        self.maximumServerWait = min(max(0, maximumServerWait), self.totalDeadline)
    }

    static func interactive(totalDeadline: TimeInterval) -> Self {
        Self(totalDeadline: totalDeadline, maximumServerWait: 30)
    }

    static func automated(totalDeadline: TimeInterval) -> Self {
        Self(totalDeadline: totalDeadline, maximumServerWait: 300)
    }

    func allowsServerWait(_ delay: TimeInterval) -> Bool {
        delay >= 0 && delay <= maximumServerWait
    }
}

/// Namespace for the request budgets and HTTP operations shared by cloud providers.
enum LLMHTTP {
    /// Timeout for summary requests. `URLSession.shared`'s default (60s) is
    /// tuned for small JSON calls; a long meeting transcript makes the model
    /// generate for minutes, and the non-streaming request only completes when
    /// the whole generation finishes. Mirrors the transcribe path's 300s.
    static let summaryTimeout: TimeInterval = 300
    static let transcriptionTimeout: TimeInterval = 300
    /// Output budget for summary generations. The previous 2000-token cap cut
    /// long-meeting summaries off mid-JSON, which then failed to parse; 8192
    /// leaves room for a detailed multi-section summary on every vendor.
    static let summaryMaxOutputTokens = 8192
    /// Output budget for chat replies. Smaller than a summary — a grounded
    /// answer over retrieved passages is short — but generous enough for a
    /// multi-paragraph explanation with quotes.
    static let chatMaxOutputTokens = 4096
    /// Documents are longer than interactive replies and reasoning models may
    /// consume part of this budget before emitting visible text.
    static let documentMaxOutputTokens = 8192
    /// Timeout for chat requests. Shorter than a summary (which can generate for
    /// minutes over a whole transcript); a RAG answer over a few passages is
    /// quick, and a snappier timeout keeps the chat UI responsive.
    static let chatTimeout: TimeInterval = 120
    /// Total attempts (initial try + retries) for a transient failure.
    static let maxAttempts = 3
    /// Base unit for exponential backoff. Kept small so the UI isn't blocked
    /// long; the user is waiting on a transcription/summary.
    static let baseDelay: TimeInterval = 0.5
    /// Upper bound on client-computed exponential backoff. Server-directed waits
    /// are exact and governed by the operation's `HTTPPolicy` instead.
    static let maxDelay: TimeInterval = 8

    /// Transport-level `URLError` codes worth retrying — momentary connectivity
    /// blips and timeouts rather than permanent misconfiguration.
    static let retriableURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost,
        .notConnectedToInternet, .dnsLookupFailed
    ]
    static let ambiguousURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost
    ]
    /// HTTP status codes worth retrying: request timeout, rate limiting, and
    /// transient server-side failures. Auth/validation errors (4xx) fail fast.
    static let retriableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
}

//
//  ProviderHTTPTransport.swift
//  Kurn
//

import Foundation
import KurnCore

extension LLMHTTP {
    /// Send the request and validate its response, retrying transient transport
    /// and server failures with exponential backoff (honoring `Retry-After`).
    /// This is the entry point providers should use; `send`/`validate` remain
    /// available for callers that need the two steps separately.
    static func sendValidated(
        _ request: URLRequest,
        session: URLSession,
        clock: some MonotonicSleepClock = SystemClock(),
        policy: HTTPPolicy? = nil,
        wallNow: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> (Data, URLResponse) {
        let policy = policy ?? .interactive(totalDeadline: max(request.timeoutInterval, 1))
        let startedAt = clock.now
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let remaining = policy.totalDeadline - (clock.now - startedAt)
            guard remaining > 0 else { throw deadlineError }
            var attemptRequest = request
            let requestedTimeout = max(request.timeoutInterval, 0.001)
            attemptRequest.timeoutInterval = remaining + 0.001 >= requestedTimeout
                ? requestedTimeout
                : remaining

            let result: (data: Data, response: URLResponse)
            do {
                result = try await send(
                    attemptRequest,
                    session: session,
                    maxResponseBytes: policy.maxResponseBytes,
                    deadlineAt: startedAt + policy.totalDeadline,
                    clock: clock
                )
            } catch let AppError.networkError(urlError) {
                guard let delay = retryableDelay(
                    attempt: attempt, status: nil, urlError: urlError, retryAfter: nil
                ) else { throw AppError.networkError(urlError) }
                try await backoffWithinDeadline(
                    delay,
                    attempt: attempt,
                    reason: "network \(urlError.code.rawValue)",
                    deadlineAt: startedAt + policy.totalDeadline,
                    clock: clock
                )
                attempt += 1
                continue
            }

            do {
                try validate(response: result.response, data: result.data)
                return result
            } catch let AppError.apiError(status, message) {
                let retryAfter = retryAfterSeconds(from: result.response, now: wallNow())
                guard let delay = retryableDelay(
                    attempt: attempt, status: status, urlError: nil, retryAfter: retryAfter
                ) else { throw AppError.apiError(statusCode: status, message: message) }
                if retryAfter != nil, !policy.allowsServerWait(delay) {
                    throw AppError.apiError(statusCode: status, message: message)
                }
                try await backoffWithinDeadline(
                    delay,
                    attempt: attempt,
                    reason: "HTTP \(status)",
                    deadlineAt: startedAt + policy.totalDeadline,
                    clock: clock
                )
                attempt += 1
            }
        }
    }

    /// Perform the request, mapping transport failures to `AppError.networkError`.
    static func send(
        _ request: URLRequest,
        session: URLSession,
        maxResponseBytes: Int,
        deadlineAt: TimeInterval,
        clock: some MonotonicSleepClock
    ) async throws -> (Data, URLResponse) {
        guard let approvedURL = request.url else { throw AppError.invalidProviderURL }
        let delegate = BoundedHTTPDataDelegate(
            approvedURL: approvedURL,
            maxResponseBytes: maxResponseBytes,
            deadlineAt: deadlineAt,
            now: { clock.now }
        )
        let controlledSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { controlledSession.invalidateAndCancel() }
        do {
            return try await delegate.execute(request, session: controlledSession)
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw AppError.networkError(error)
        }
    }

    /// Throw `AppError.apiError` for any non-2xx response, extracting the
    /// vendor's error message when present.
    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let message = decodeErrorMessage(data) ?? "request failed"
            throw AppError.apiError(statusCode: http.statusCode, message: message)
        }
    }

    /// Decide whether the attempt that just failed should be retried, and after
    /// how long. `attempt` is zero-based (0 = first try). Returns `nil` when the
    /// failure is non-transient or the attempt budget is exhausted.
    static func retryableDelay(
        attempt: Int,
        status: Int?,
        urlError: URLError?,
        retryAfter: TimeInterval?,
        jitter: TimeInterval? = nil
    ) -> TimeInterval? {
        guard attempt < maxAttempts - 1 else { return nil }

        let isTransient: Bool
        if let status {
            isTransient = retriableStatusCodes.contains(status)
        } else if let urlError {
            isTransient = retriableURLErrorCodes.contains(urlError.code)
        } else {
            isTransient = false
        }
        guard isTransient else { return nil }

        // A server-provided Retry-After wins over our own backoff.
        if let retryAfter {
            return max(0, retryAfter)
        }
        let exponential = baseDelay * pow(2, Double(attempt))
        let jitter = jitter.map { min(max($0, 0), baseDelay) }
            ?? Double.random(in: 0...baseDelay)
        return min(exponential + jitter, maxDelay)
    }

    private static var deadlineError: AppError {
        .networkError(URLError(.timedOut))
    }

    private static func backoffWithinDeadline(
        _ delay: TimeInterval,
        attempt: Int,
        reason: String,
        deadlineAt: TimeInterval,
        clock: some MonotonicSleepClock
    ) async throws {
        let remaining = deadlineAt - clock.now
        guard delay < remaining else { throw deadlineError }
        try await backoff(delay, attempt: attempt, reason: reason, clock: clock)
    }

    private static func backoff(
        _ delay: TimeInterval,
        attempt: Int,
        reason: String,
        clock: some SleepClock
    ) async throws {
        let seconds = String(format: "%.2f", delay)
        let nextAttempt = attempt + 2
        AppLog.transcription.atInfo.info("http: retrying after \(seconds, privacy: .public)s (attempt \(nextAttempt, privacy: .public)/\(maxAttempts, privacy: .public), \(reason, privacy: .public))")
        try await clock.sleep(seconds: delay)
    }

    static func retryAfterSeconds(
        from response: URLResponse,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = TimeInterval(raw), seconds.isFinite {
            return seconds
        }
        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    private static func decodeErrorMessage(_ data: Data) -> String? {
        struct Envelope: Decodable { struct E: Decodable { let message: String }; let error: E }
        return try? JSONDecoder().decode(Envelope.self, from: data).error.message
    }
}

private final class BoundedHTTPDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Output = (Data, URLResponse)

    private let lock = NSLock()
    private let approvedURL: URL
    private let maxResponseBytes: Int
    private let deadlineAt: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var continuation: CheckedContinuation<Output, Error>?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var buffer = Data()
    private var terminalError: Error?
    private var cancelled = false
    private var completed = false

    init(
        approvedURL: URL,
        maxResponseBytes: Int,
        deadlineAt: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.approvedURL = approvedURL
        self.maxResponseBytes = maxResponseBytes
        self.deadlineAt = deadlineAt
        self.now = now
    }

    func execute(_ request: URLRequest, session: URLSession) async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let cancelled = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    task.resume()
                    return self.cancelled
                }
                if cancelled { task.cancel() }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirected = LLMHTTP.redirectRequest(
            approvedURL: approvedURL,
            proposedRequest: request
        )
        if redirected == nil {
            AppLog.transcription.atError.error(
                "http: rejected cross-origin redirect task=\(task.taskIdentifier, privacy: .public)"
            )
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let shouldCancel = lock.withLock {
            self.response = response
            if now() >= deadlineAt {
                terminalError = AppError.networkError(URLError(.timedOut))
                return true
            }
            if response.expectedContentLength > Int64(maxResponseBytes) {
                terminalError = AppError.providerResponseTooLarge
                return true
            }
            return false
        }
        completionHandler(shouldCancel ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldCancel = lock.withLock {
            guard terminalError == nil else { return true }
            if now() >= deadlineAt {
                terminalError = AppError.networkError(URLError(.timedOut))
                return true
            }
            guard data.count <= maxResponseBytes - buffer.count else {
                terminalError = AppError.providerResponseTooLarge
                return true
            }
            buffer.append(data)
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (CheckedContinuation<Output, Error>, Result<Output, Error>)? = lock.withLock {
            guard !completed, let continuation else { return nil }
            completed = true
            self.continuation = nil
            self.task = nil
            let result: Result<Output, Error>
            if let terminalError {
                result = .failure(terminalError)
            } else if now() >= deadlineAt {
                result = .failure(AppError.networkError(URLError(.timedOut)))
            } else if cancelled {
                result = .failure(CancellationError())
            } else if let error {
                result = .failure(error)
            } else if let response {
                result = .success((buffer, response))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            return (continuation, result)
        }
        guard let completion else { return }
        completion.0.resume(with: completion.1)
    }
}

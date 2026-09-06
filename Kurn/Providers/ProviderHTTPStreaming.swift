//
//  ProviderHTTPStreaming.swift
//  Kurn
//
//  Server-Sent-Events streaming transport for `LLMProvider.streamChat`, held
//  to the same resilience contract `ProviderHTTPTransport.swift` gives every
//  other request: origin-locked redirects, a total deadline, and a
//  cumulative response-size cap. `BoundedSSEDataDelegate.execute` is one
//  structured `withTaskCancellationHandler` call awaited directly in the
//  caller's task — the same shape `BoundedHTTPDataDelegate.execute` uses —
//  so cancelling the task that called `streamChat` cancels the in-flight
//  request instead of leaving it running in an orphaned background task.
//
//  Streaming has no retry loop (unlike `sendValidated`): a stream either
//  connects and delivers text, or it fails outright. Retrying a partially
//  delivered generation would mean re-showing already-rendered text or
//  silently dropping it, and `Retry-After` has no meaning once a response
//  has started streaming, so this deliberately does not attempt either.
//

import Foundation
import KurnCore

extension LLMHTTP {
    /// Stream a Server-Sent-Events response, invoking `onPayload` once per
    /// `data:` line as it arrives (skipping the literal `[DONE]` sentinel
    /// some vendors send, and any non-`data:` line). A non-2xx response is
    /// read to completion — bounded by `policy.maxResponseBytes`, same as the
    /// non-streaming path — and surfaced as `AppError.apiError`.
    static func streamSSE(
        _ request: URLRequest,
        session: URLSession,
        policy: HTTPPolicy,
        clock: some MonotonicSleepClock = SystemClock(),
        onPayload: @escaping @Sendable (String) throws -> Void
    ) async throws {
        guard let approvedURL = request.url else { throw AppError.invalidProviderURL }
        var boundedRequest = request
        boundedRequest.timeoutInterval = policy.totalDeadline
        let delegate = BoundedSSEDataDelegate(
            approvedURL: approvedURL,
            maxResponseBytes: policy.maxResponseBytes,
            deadlineAt: clock.now + policy.totalDeadline,
            now: { clock.now },
            onPayload: onPayload
        )
        // Short-lived, custom-delegate session needed to enforce this same
        // origin-locked, deadline-bounded policy on a streaming response —
        // the same shape as ProviderHTTPTransport.swift's
        // BoundedHTTPDataDelegate, not a bypass of it.
        // static-policy:allow custom-url-session
        let controlledSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { controlledSession.invalidateAndCancel() }
        do {
            try await delegate.execute(boundedRequest, session: controlledSession)
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            if let restriction = LargeTransferPolicy.restrictionError(for: error) {
                throw restriction
            }
            throw AppError.networkError(error)
        }
    }
}

/// Thread-safe accumulator for streamed text. `LLMProvider.streamChat`
/// conformers (tracking whether any visible text arrived) and
/// `MeetingChatService.streamAnswer` (building the final answer) both fold
/// delta callbacks — delivered from a URLSession delegate queue — into one
/// running value; Swift 6 requires that folding go through something the
/// compiler can see is safe to share across the `@Sendable` closure boundary.
final class StreamingAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ delta: String) {
        lock.withLock { text += delta }
    }

    var value: String { lock.withLock { text } }
    var receivedText: Bool { lock.withLock { !text.isEmpty } }
}

/// Drives one streaming request and incrementally parses its
/// `text/event-stream` body into SSE payload lines, forwarding each through
/// `onPayload`. Mirrors `BoundedHTTPDataDelegate`'s redirect lock, deadline,
/// and size cap, adapted to push lines out as they arrive instead of
/// returning one buffered `Data` at the end — a long-running generation must
/// stay bounded exactly like a buffered response would, without holding the
/// whole reply in memory twice.
private final class BoundedSSEDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let approvedURL: URL
    private let maxResponseBytes: Int
    private let deadlineAt: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let onPayload: @Sendable (String) throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var httpStatus: Int?
    private var lineBuffer = Data()
    private var errorBodyBuffer = Data()
    private var totalBytesReceived = 0
    private var terminalError: Error?
    private var cancelled = false
    private var completed = false

    init(
        approvedURL: URL,
        maxResponseBytes: Int,
        deadlineAt: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval,
        onPayload: @escaping @Sendable (String) throws -> Void
    ) {
        self.approvedURL = approvedURL
        self.maxResponseBytes = maxResponseBytes
        self.deadlineAt = deadlineAt
        self.now = now
        self.onPayload = onPayload
    }

    func execute(_ request: URLRequest, session: URLSession) async throws {
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
        let redirected = LLMHTTP.redirectRequest(approvedURL: approvedURL, proposedRequest: request)
        if redirected == nil {
            AppLog.transcription.atError.error(
                "http: rejected cross-origin redirect (stream) task=\(task.taskIdentifier, privacy: .public)"
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
            httpStatus = (response as? HTTPURLResponse)?.statusCode
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
        let outcome: (cancel: Bool, payloads: [String])? = lock.withLock {
            guard terminalError == nil else { return (true, []) }
            if now() >= deadlineAt {
                terminalError = AppError.networkError(URLError(.timedOut))
                return (true, [])
            }
            guard data.count <= maxResponseBytes - totalBytesReceived else {
                terminalError = AppError.providerResponseTooLarge
                return (true, [])
            }
            totalBytesReceived += data.count

            // A non-2xx response is an error body, not an SSE stream: buffer
            // it (bounded by the cap above) and decode it on completion, the
            // same shape `LLMHTTP.validate` uses for the non-streaming path.
            guard let httpStatus, (200...299).contains(httpStatus) else {
                errorBodyBuffer.append(data)
                return (false, [])
            }

            lineBuffer.append(data)
            return (false, drainCompleteLines())
        }
        guard let outcome else { return }
        for payload in outcome.payloads {
            do {
                try onPayload(payload)
            } catch {
                // `onPayload` rejected this payload (e.g. Anthropic's
                // mid-stream `error` event) — fail the whole call rather
                // than deliver any more text.
                lock.withLock { terminalError = error }
                dataTask.cancel()
                return
            }
        }
        if outcome.cancel { dataTask.cancel() }
    }

    /// Split `lineBuffer` on `\n`, keeping any trailing partial line for the
    /// next call, and return the `data:` payloads found. A `\n` byte can
    /// never appear inside a multi-byte UTF-8 sequence (continuation bytes
    /// are always `0x80`–`0xBF`), so splitting on it is always a safe
    /// decode boundary. Must be called with `lock` held.
    private func drainCompleteLines() -> [String] {
        var payloads: [String] = []
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[..<newlineIndex]
            lineBuffer.removeSubrange(...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmedLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard trimmedLine.hasPrefix("data:") else { continue }
            let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", !payload.isEmpty else { continue }
            payloads.append(payload)
        }
        return payloads
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (CheckedContinuation<Void, Error>, Result<Void, Error>)? = lock.withLock {
            guard !completed, let continuation else { return nil }
            completed = true
            self.continuation = nil
            self.task = nil
            let result: Result<Void, Error>
            if let terminalError {
                result = .failure(terminalError)
            } else if now() >= deadlineAt {
                result = .failure(AppError.networkError(URLError(.timedOut)))
            } else if cancelled {
                result = .failure(CancellationError())
            } else if let error {
                result = .failure(error)
            } else if let httpStatus, !(200...299).contains(httpStatus) {
                let message = LLMHTTP.decodeErrorMessage(errorBodyBuffer) ?? "request failed"
                result = .failure(AppError.apiError(statusCode: httpStatus, message: message))
            } else {
                result = .success(())
            }
            return (continuation, result)
        }
        guard let completion else { return }
        completion.0.resume(with: completion.1)
    }
}

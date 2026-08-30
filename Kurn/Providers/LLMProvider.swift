//
//  LLMProvider.swift
//  Kurn
//
//  Abstraction over the cloud vendors. Transcription is only meaningful for
//  vendors that expose a speech endpoint (OpenAI Whisper); summary generation is
//  supported by both. Implementations talk to their HTTP APIs via URLSession and
//  must be safe to call from any task (`Sendable`).
//

import Foundation
import KurnCore

/// Structured summary returned by a chat/messages completion. The shape is
/// template-driven, so it is just an ordered list of titled sections.
struct SummaryResult: Sendable {
    var sections: [SummarySection]
}

/// One turn in a chat conversation. `system` is passed separately to
/// `LLMProvider.chat`, so message lists normally hold only `user`/`assistant`.
struct ChatMessage: Sendable, Equatable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Request budget for free-form text generation. Interactive chat stays
/// responsive, while document generation gets the same room and timeout as a
/// full meeting summary.
struct TextGenerationOptions: Sendable, Equatable {
    let maxOutputTokens: Int
    let timeout: TimeInterval

    static let chat = Self(
        maxOutputTokens: LLMHTTP.chatMaxOutputTokens,
        timeout: LLMHTTP.chatTimeout
    )
    static let document = Self(
        maxOutputTokens: LLMHTTP.documentMaxOutputTokens,
        timeout: LLMHTTP.summaryTimeout
    )
}

protocol LLMProvider: Sendable {
    /// Vendor this provider represents.
    var provider: AIProvider { get }

    /// Transcribe a single audio blob (one chunk). `language` is a hint; the
    /// returned `RawTranscript.language` reflects what the service detected.
    /// Vendors without speech support throw `AppError.transcriptionFailed`.
    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript

    /// Produce a structured meeting summary from a fully built prompt.
    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult

    /// Free-form multi-turn chat completion. Unlike `summarize`, this returns
    /// plain text (no JSON-section contract), so it backs the "chat with your
    /// meetings" feature. `systemPrompt` carries the grounding instructions;
    /// `messages` are the user/assistant turns in order.
    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String
}

extension LLMProvider {
    /// Default for vendors with no speech endpoint wired here.
    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString("error.provider_no_transcribe", comment: "Provider has no transcription")
        )
    }

    func chat(systemPrompt: String, messages: [ChatMessage]) async throws -> String {
        try await chat(systemPrompt: systemPrompt, messages: messages, options: .chat)
    }
}

// MARK: - Shared HTTP helpers

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

/// HTTP plumbing shared by the cloud providers: both OpenAI and Anthropic talk
/// to JSON APIs that report failures as `{ "error": { "message" } }`.
enum LLMHTTP {
    /// Timeout for summary requests. `URLSession.shared`'s default (60s) is
    /// tuned for small JSON calls; a long meeting transcript makes the model
    /// generate for minutes, and the non-streaming request only completes when
    /// the whole generation finishes. Mirrors the transcribe path's 300s.
    static let summaryTimeout: TimeInterval = 300
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
    /// HTTP status codes worth retrying: request timeout, rate limiting, and
    /// transient server-side failures. Auth/validation errors (4xx) fail fast.
    static let retriableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    static func isValidBaseURL(_ baseURLString: String) -> Bool {
        validatedBaseURLComponents(baseURLString) != nil
    }

    static func endpoint(baseURLString: String, path: String) -> URL? {
        guard var components = validatedBaseURLComponents(baseURLString),
              !containsUnsafePath(path) else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }

    static func requireEndpoint(provider: AIProvider, path: String) throws -> URL {
        guard let url = endpoint(baseURLString: provider.baseURLString, path: path) else {
            throw AppError.invalidProviderURL
        }
        return url
    }

    static func redirectRequest(
        approvedURL: URL,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        guard let proposedURL = proposedRequest.url,
              let approvedOrigin = HTTPOrigin(approvedURL),
              let proposedOrigin = HTTPOrigin(proposedURL),
              approvedOrigin == proposedOrigin else { return nil }
        return proposedRequest
    }

    /// Fail fast with `AppError.noAPIKey` when a provider has no configured key.
    static func requireAPIKey(_ key: String, provider: AIProvider) throws {
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }
    }

    /// Build a `POST <base URL>/<path>` request carrying a JSON body — the shape
    /// every vendor's summary and chat call shares. `headers` carries the vendor's
    /// auth style (`Authorization: Bearer`, `x-api-key`, `x-goog-api-key`) on top
    /// of the JSON `Content-Type` set here.
    static func jsonRequest(
        provider: AIProvider,
        path: String,
        timeout: TimeInterval,
        headers: [String: String],
        body: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: try requireEndpoint(provider: provider, path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct HTTPOrigin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = components.host?.lowercased(),
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = components.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    private static func validatedBaseURLComponents(_ baseURLString: String) -> URLComponents? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              !isDisallowedHost(host),
              !containsUnsafePath(components.percentEncodedPath) else { return nil }
        return components
    }

    private static func containsUnsafePath(_ path: String) -> Bool {
        var decoded = path
        while true {
            guard let next = decoded.removingPercentEncoding else { return true }
            if next == decoded { break }
            decoded = next
        }
        let normalized = decoded.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0 == "." || $0 == ".."
        }
    }

    private static func isDisallowedHost(_ host: String) -> Bool {
        if host.contains(":") { return true }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return true }
        if host == "localhost" || host == "home.arpa" { return true }
        let localSuffixes = [".localhost", ".local", ".internal", ".lan", ".home", ".home.arpa"]
        if localSuffixes.contains(where: host.hasSuffix) { return true }
        return isIPv4Literal(host)
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.allSatisfy(\.isNumber)
        }
    }

    /// Decode a summary response, extract its text content, and parse the shared
    /// JSON contract into a `SummaryResult`. Centralizes the decode→parse→error
    /// flow every provider's `summarize` shares. `isTruncated` inspects the
    /// vendor's finish/stop reason: a generation cut off by the output-token cap
    /// is syntactically broken JSON, so surface the specific truncation error
    /// instead of the confusing decode failure it would otherwise become. The
    /// first catch deliberately re-throws `AppError`s (e.g. the empty-content
    /// and `SummaryJSON.parse` failures) so they aren't re-wrapped by the
    /// generic `decodingError` catch.
    static func summaryResult<T: Decodable>(
        from data: Data,
        as type: T.Type,
        emptyMessage: String,
        isTruncated: (T) -> Bool = { _ in false },
        extractContent: (T) -> String?
    ) throws -> SummaryResult {
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            guard !isTruncated(decoded) else {
                throw AppError.summaryTruncated
            }
            guard let content = extractContent(decoded), !content.isEmpty else {
                throw AppError.decodingError(emptyMessage)
            }
            let json = try SummaryJSON.parse(content)
            return SummaryResult(sections: json.summarySections)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }

    /// Decode a chat response and extract its plain-text content. The
    /// text sibling of `summaryResult`: no JSON-section parsing, just the
    /// model's reply. Re-throws `AppError`s (e.g. the empty-content failure) so
    /// they aren't re-wrapped by the generic decode catch.
    static func textResult<T: Decodable>(
        from data: Data,
        as type: T.Type,
        emptyMessage: String,
        isTruncated: (T) -> Bool = { _ in false },
        extractContent: (T) -> String?
    ) throws -> String {
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            guard !isTruncated(decoded) else {
                throw AppError.generationTruncated
            }
            guard let content = extractContent(decoded)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw AppError.decodingError(emptyMessage)
            }
            return content
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }

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

    private static func backoff(_ delay: TimeInterval, attempt: Int, reason: String, clock: some SleepClock) async throws {
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

// MARK: - Shared response shape (OpenAI-compatible)

/// Chat Completions response shared by OpenAI and the OpenAI-compatible Groq API.
struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            // Reasoning models can return `content: null` when the output-token
            // budget is exhausted before visible text is produced. Refusals
            // likewise arrive separately from normal content.
            let content: String?
            let refusal: String?
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]

    /// True when generation stopped because it hit the output-token cap, which
    /// leaves the JSON payload cut off mid-structure.
    var isTruncated: Bool { choices.first?.finishReason == "length" }
}

// `SummaryJSON` and `ModelJSON` now live in the KurnCore package
// (`Sources/KurnCore/Providers/SummaryJSON.swift`) — no URLSession
// dependency, unlike everything else in this file.

// MARK: - Shared prompt

enum SummaryPrompt {
    /// Build the system prompt for a template. Combines a fixed base + the
    /// template's persona/focus + its suggested sections + the JSON contract.
    /// The summary is requested in the transcript's own language.
    static func system(for template: SummaryTemplate) -> String {
        var prompt = """
        You are an expert meeting assistant. Given a meeting transcript with \
        speaker labels, produce a structured summary in the SAME LANGUAGE as the \
        transcript.

        Some transcript lines are prefixed with ⭐ — these mark moments the \
        speaker explicitly flagged as important while the meeting was being \
        recorded. Whenever at least one ⭐-marked line is present, include a \
        dedicated section (title translated into the transcript's language, \
        along the lines of "Highlighted Moments") listing each one with its \
        [mm:ss] timestamp and a short description of what was said, in \
        chronological order.

        \(template.instructions)
        """

        let sections = template.sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !sections.isEmpty {
            let list = sections.map { "- \($0)" }.joined(separator: "\n")
            prompt += """


            Organize the summary into sections along these lines (adapt, merge, \
            rename, or add sections as the content requires):
            \(list)
            """
        }

        prompt += """


        Output valid JSON with this shape:
        {
          "sections": [
            { "title": "Section heading", "body": "markdown paragraph(s)", "items": ["bullet", "bullet"] }
          ]
        }
        Each section needs a "title". Use "body" for prose and "items" for bullet \
        lists; either may be omitted when not needed.
        "body" is rendered as Markdown and supports: **bold** and *italic*, #### \
        subheadings, bullet and numbered lists (nest by indenting two spaces), task \
        checkboxes ("- [ ]" open, "- [x]" done), "> " blockquotes, pipe tables with \
        a |---| separator row, and ``` fenced code blocks.
        Prefer task checkboxes for action items and to-dos (include owner and \
        deadline when stated), a table when comparing options or listing structured \
        facts, and "> " blockquotes when quoting a speaker verbatim. Use plain \
        prose everywhere else — do not force formatting where it does not help.
        "items" entries render as bullets; start an entry with "[ ] " or "[x] " to \
        render it as a task checkbox instead.
        Use real line breaks inside "body" — never write the two characters \
        backslash-n. Keep each "items" entry to a single line.
        Translate the section titles into the transcript's language.
        Output ONLY the JSON object itself — no markdown fences around it.
        """
        return prompt
    }
}

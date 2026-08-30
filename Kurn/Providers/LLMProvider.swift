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

    /// Streaming variant of `chat`: yields the reply as text deltas whose
    /// concatenation is the same string `chat` would have returned, so the
    /// chat UI can render an answer as it's generated instead of waiting for
    /// the whole thing. A conformer with no true streaming transport falls
    /// back to the `LLMProvider` extension's default below, which just wraps
    /// `chat` as a single-chunk stream — still correct, just not incremental.
    func streamChat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) -> AsyncThrowingStream<String, Error>
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

    func streamChat(systemPrompt: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        streamChat(systemPrompt: systemPrompt, messages: messages, options: .chat)
    }

    /// Default streaming implementation: awaits the whole `chat` reply and
    /// yields it as one delta. Correct for any conformer (including test
    /// doubles that only implement `chat`), just not incremental.
    func streamChat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        let box = LLMHTTP.SingleShotBox()
        return AsyncThrowingStream(unfolding: {
            if box.consumed { return nil }
            box.consumed = true
            return try await chat(systemPrompt: systemPrompt, messages: messages, options: options)
        })
    }
}

// MARK: - Shared HTTP helpers

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
    /// Upper bound on any single backoff wait, including a server `Retry-After`.
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

    static func endpoint(baseURLString: String, path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: baseURLString) else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return components.url
    }

    /// Fail fast with `AppError.noAPIKey` when a provider has no configured key.
    static func requireAPIKey(_ key: String, provider: AIProvider) throws {
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }
    }

    /// Build a `POST <base URL>/<path>` request carrying a JSON body — the shape
    /// every vendor's summary and chat call shares. `fallbackURL` is used when the
    /// user-configured base URL can't be parsed into components, and `headers`
    /// carries the vendor's auth style (`Authorization: Bearer`, `x-api-key`,
    /// `x-goog-api-key`) on top of the JSON `Content-Type` set here.
    static func jsonRequest(
        provider: AIProvider,
        path: String,
        fallbackURL: String,
        timeout: TimeInterval,
        headers: [String: String],
        queryItems: [URLQueryItem] = [],
        body: [String: Any]
    ) throws -> URLRequest {
        let url = endpoint(baseURLString: provider.baseURLString, path: path, queryItems: queryItems)
            ?? URL(string: fallbackURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
        clock: some SleepClock = SystemClock()
    ) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            // Transport step. Only `AppError.networkError` is retriable here;
            // anything else (e.g. cancellation) propagates immediately.
            let result: (data: Data, response: URLResponse)
            do {
                result = try await send(request, session: session)
            } catch let AppError.networkError(urlError) {
                guard let delay = retryableDelay(
                    attempt: attempt, status: nil, urlError: urlError, retryAfter: nil
                ) else { throw AppError.networkError(urlError) }
                try await backoff(delay, attempt: attempt, reason: "network \(urlError.code.rawValue)", clock: clock)
                attempt += 1
                continue
            }

            // Validation step. A retriable status code (429/5xx/…) backs off and
            // retries; any other API error fails fast.
            do {
                try validate(response: result.response, data: result.data)
                return result
            } catch let AppError.apiError(status, message) {
                let retryAfter = retryAfterSeconds(from: result.response)
                guard let delay = retryableDelay(
                    attempt: attempt, status: status, urlError: nil, retryAfter: retryAfter
                ) else { throw AppError.apiError(statusCode: status, message: message) }
                try await backoff(delay, attempt: attempt, reason: "HTTP \(status)", clock: clock)
                attempt += 1
                continue
            }
        }
    }

    /// Perform the request, mapping transport failures to `AppError.networkError`.
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
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

    // MARK: - Streaming (Server-Sent Events)

    /// Server-Sent-Events payloads for a streaming request (`text/event-stream`
    /// response). Yields each event's raw `data:` payload (the JSON chunk vendors
    /// send, or the literal `[DONE]` sentinel some of them emit, which ends the
    /// stream here rather than being yielded); a non-2xx response is read to
    /// completion and surfaced as `AppError.apiError`, the same failure shape as
    /// the non-streaming path.
    ///
    /// Built with `AsyncThrowingStream(unfolding:)` rather than a producer
    /// `Task`, so the underlying `URLSession.bytes(for:)` read is awaited
    /// directly inside the caller's own task. That preserves the same
    /// cancellation guarantee `sendValidated` has: cancelling the task that is
    /// iterating this stream cancels the in-flight request, instead of leaving
    /// it running in an orphaned background task.
    static func sseLines(for request: URLRequest, session: URLSession) -> AsyncThrowingStream<String, Error> {
        let box = LineIteratorBox()
        return AsyncThrowingStream(unfolding: {
            if box.iterator == nil {
                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do {
                    (bytes, response) = try await session.bytes(for: request)
                } catch let error as URLError {
                    throw AppError.networkError(error)
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    let message = decodeErrorMessage(data) ?? "request failed"
                    throw AppError.apiError(statusCode: http.statusCode, message: message)
                }
                box.iterator = bytes.lines.makeAsyncIterator()
            }
            while let line = try await box.iterator?.next() {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { return nil }
                guard !payload.isEmpty else { continue }
                return payload
            }
            return nil
        })
    }

    /// Build a streaming chat reply: lazily builds the request on the first
    /// pull (so a `requireAPIKey`/`makeRequest` failure throws at the same
    /// point the non-streaming path would), maps each SSE payload through
    /// `mapPayload` (returning `nil` to skip an event with no visible text,
    /// e.g. Anthropic's `ping`/`message_stop`), and forwards only non-empty
    /// deltas. Throws `emptyMessage` as `AppError.decodingError` if the stream
    /// finishes having produced no visible text at all — the streaming sibling
    /// of `textResult`'s empty-content guard.
    static func streamChatDeltas(
        session: URLSession,
        emptyMessage: String,
        makeRequest: @escaping @Sendable () throws -> URLRequest,
        mapPayload: @escaping @Sendable (String) throws -> String?
    ) -> AsyncThrowingStream<String, Error> {
        let state = DeltaStreamState()
        return AsyncThrowingStream(unfolding: {
            if state.iterator == nil {
                let request = try makeRequest()
                state.iterator = sseLines(for: request, session: session).makeAsyncIterator()
            }
            while let payload = try await state.iterator?.next() {
                guard let delta = try mapPayload(payload), !delta.isEmpty else { continue }
                state.sawContent = true
                return delta
            }
            guard state.sawContent else {
                throw AppError.decodingError(emptyMessage)
            }
            return nil
        })
    }

    /// Decide whether the attempt that just failed should be retried, and after
    /// how long. `attempt` is zero-based (0 = first try). Returns `nil` when the
    /// failure is non-transient or the attempt budget is exhausted.
    static func retryableDelay(
        attempt: Int,
        status: Int?,
        urlError: URLError?,
        retryAfter: TimeInterval?
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
        if let retryAfter, retryAfter > 0 {
            return min(retryAfter, maxDelay)
        }
        let exponential = baseDelay * pow(2, Double(attempt))
        let jitter = Double.random(in: 0...baseDelay)
        return min(exponential + jitter, maxDelay)
    }

    private static func backoff(_ delay: TimeInterval, attempt: Int, reason: String, clock: some SleepClock) async throws {
        let seconds = String(format: "%.2f", delay)
        let nextAttempt = attempt + 2
        AppLog.transcription.atInfo.info("http: retrying after \(seconds, privacy: .public)s (attempt \(nextAttempt, privacy: .public)/\(maxAttempts, privacy: .public), \(reason, privacy: .public))")
        try await clock.sleep(seconds: delay)
    }

    /// Parse a `Retry-After` header expressed in delta-seconds. The HTTP-date
    /// form is permitted by the spec but unused by these vendors, so it's ignored.
    private static func retryAfterSeconds(from response: URLResponse) -> TimeInterval? {
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return seconds
    }

    private static func decodeErrorMessage(_ data: Data) -> String? {
        struct Envelope: Decodable { struct E: Decodable { let message: String }; let error: E }
        return try? JSONDecoder().decode(Envelope.self, from: data).error.message
    }

    /// Boxes the lazily-created line iterator so `sseLines`'s `unfolding`
    /// closure can hold mutable state across calls. Safe as `@unchecked
    /// Sendable`: `AsyncThrowingStream(unfolding:)` serializes calls to the
    /// closure, so there is never more than one call to `next()` in flight.
    final class LineIteratorBox: @unchecked Sendable {
        var iterator: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator?
    }

    /// Boxes `streamChatDeltas`'s mutable state (the payload iterator, and
    /// whether any visible text has been produced yet) for the same reason and
    /// under the same serialization guarantee as `LineIteratorBox`.
    final class DeltaStreamState: @unchecked Sendable {
        var iterator: AsyncThrowingStream<String, Error>.Iterator?
        var sawContent = false
    }

    /// Boxes the "have we already produced our one chunk" flag for the
    /// `LLMProvider` extension's default `streamChat` fallback, under the same
    /// serialization guarantee as the boxes above.
    final class SingleShotBox: @unchecked Sendable {
        var consumed = false
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

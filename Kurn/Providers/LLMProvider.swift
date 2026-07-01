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

/// Structured summary returned by a chat/messages completion. The shape is
/// template-driven, so it is just an ordered list of titled sections.
struct SummaryResult: Sendable {
    var sections: [SummarySection]
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

    static func endpoint(baseURLString: String, path: String) -> URL? {
        guard var components = URLComponents(string: baseURLString) else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }

    /// Fail fast with `AppError.noAPIKey` when a provider has no configured key.
    static func requireAPIKey(_ key: String, provider: AIProvider) throws {
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }
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

    /// Send the request and validate its response, retrying transient transport
    /// and server failures with exponential backoff (honoring `Retry-After`).
    /// This is the entry point providers should use; `send`/`validate` remain
    /// available for callers that need the two steps separately.
    static func sendValidated(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
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
                try await backoff(delay, attempt: attempt, reason: "network \(urlError.code.rawValue)")
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
                try await backoff(delay, attempt: attempt, reason: "HTTP \(status)")
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

    private static func backoff(_ delay: TimeInterval, attempt: Int, reason: String) async throws {
        let seconds = String(format: "%.2f", delay)
        let nextAttempt = attempt + 2
        AppLog.transcription.atInfo.info("http: retrying after \(seconds, privacy: .public)s (attempt \(nextAttempt, privacy: .public)/\(maxAttempts, privacy: .public), \(reason, privacy: .public))")
        try await Task.sleep(for: .seconds(delay))
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
}

// MARK: - Shared response shape (OpenAI-compatible)

/// Chat Completions response shared by OpenAI and the OpenAI-compatible Groq API.
struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
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

// MARK: - Shared JSON shape

/// The JSON contract all vendors are instructed to return for summaries: an
/// ordered list of titled sections, each with optional prose and/or bullets.
struct SummaryJSON: Decodable {
    struct Section: Decodable {
        let title: String
        let body: String?
        let items: [String]?
    }
    let sections: [Section]

    /// Map the wire shape into the shared `SummarySection` value type, dropping
    /// sections that carry neither a title nor any content.
    var summarySections: [SummarySection] {
        sections.compactMap { section in
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (section.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let items = (section.items ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !title.isEmpty || !body.isEmpty || !items.isEmpty else { return nil }
            return SummarySection(title: title, body: body, items: items)
        }
    }
}

extension SummaryJSON {
    /// Tolerant decode that strips accidental markdown code fences before parsing.
    static func parse(_ raw: String) throws -> SummaryJSON {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            // Drop the opening fence (``` or ```json) and the closing fence.
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceRange = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // First attempt: decode the (de-fenced) text directly.
        if let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SummaryJSON.self, from: data) {
            return decoded
        }

        // Fallback: extract the outermost { ... } object in case the model wrote
        // any prose around the JSON (more common with the Anthropic path).
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end {
            let candidate = String(text[start...end])
            if let data = candidate.data(using: .utf8) {
                do {
                    return try JSONDecoder().decode(SummaryJSON.self, from: data)
                } catch {
                    throw AppError.decodingError(error.localizedDescription)
                }
            }
        }

        throw AppError.decodingError("response did not contain valid JSON")
    }
}

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
        lists; either may be omitted when not needed. Translate the section titles \
        into the transcript's language.
        Output ONLY the JSON, no markdown fences.
        """
        return prompt
    }
}

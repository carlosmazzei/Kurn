//
//  LLMProvider.swift
//  MeetSync
//
//  Abstraction over the cloud vendors. Transcription is only meaningful for
//  vendors that expose a speech endpoint (OpenAI Whisper); summary generation is
//  supported by both. Implementations talk to their HTTP APIs via URLSession and
//  must be safe to call from any task (`Sendable`).
//

import Foundation

/// Structured summary returned by a chat/messages completion.
struct SummaryResult: Sendable {
    var content: String
    var actionItems: [String]
    var keyDecisions: [String]
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
    static func endpoint(baseURLString: String, path: String) -> URL? {
        guard var components = URLComponents(string: baseURLString) else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
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

    private static func decodeErrorMessage(_ data: Data) -> String? {
        struct Envelope: Decodable { struct E: Decodable { let message: String }; let error: E }
        return try? JSONDecoder().decode(Envelope.self, from: data).error.message
    }
}

// MARK: - Shared JSON shape

/// The JSON contract both vendors are instructed to return for summaries.
struct SummaryJSON: Decodable {
    let summary: String
    let actionItems: [String]
    let keyDecisions: [String]
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
    /// System prompt shared by both vendors; requests strict JSON in the
    /// transcript's own language.
    static let system = """
    You are an expert meeting assistant. Given a meeting transcript with speaker \
    labels, produce a structured summary in the SAME LANGUAGE as the transcript.
    Output valid JSON with this shape:
    {
      "summary": "# Meeting Summary\\n...(markdown, 3-5 paragraphs)...",
      "actionItems": ["...", "..."],
      "keyDecisions": ["...", "..."]
    }
    Output ONLY the JSON, no markdown fences.
    """
}

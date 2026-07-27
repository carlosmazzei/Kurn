//
//  GoogleProvider.swift
//  Kurn
//
//  Google Gemini implementation of summary generation via the Generative
//  Language API (models/{model}:generateContent). Gemini has no speech endpoint
//  wired here, so cloud transcription continues to route through OpenAI Whisper.
//

import Foundation

struct GoogleProvider: LLMProvider {
    let provider: AIProvider

    private let apiKey: String
    private let session: URLSession
    private let model: String

    init(provider: AIProvider = .google, apiKey: String, model: String = "gemini-1.5-pro", session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        // Gemini has no dedicated system role here; fold it into the user turn.
        let combined = "\(systemPrompt)\n\n\(userPrompt)"
        let summarySchema: [String: Any] = [
            "type": "object",
            "properties": [
                "sections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "body": ["type": "string"],
                            "items": [
                                "type": "array",
                                "items": ["type": "string"]
                            ]
                        ],
                        "required": ["title"]
                    ]
                ]
            ],
            "required": ["sections"]
        ]
        let request = try makeRequest(
            timeout: LLMHTTP.summaryTimeout,
            body: [
                "contents": [["role": "user", "parts": [["text": combined]]]],
                "generationConfig": [
                    "responseMimeType": "application/json",
                    "responseJsonSchema": summarySchema,
                    "maxOutputTokens": LLMHTTP.summaryMaxOutputTokens
                ]
            ]
        )

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.summaryResult(
            from: data,
            as: GeminiResponse.self,
            emptyMessage: "empty Gemini response",
            isTruncated: { $0.candidates?.first?.finishReason == "MAX_TOKENS" },
            extractContent: { Self.text(from: $0) }
        )
    }

    // MARK: - Chat (generateContent, plain text)

    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        // Gemini has no dedicated system role here; fold the system prompt into
        // the first user turn (as `summarize` does) and map assistant → model.
        var contents: [[String: Any]] = []
        for (index, message) in messages.enumerated() where message.role != .system {
            let role = message.role == .assistant ? "model" : "user"
            var text = message.content
            if index == 0 && message.role == .user {
                text = "\(systemPrompt)\n\n\(text)"
            }
            contents.append(["role": role, "parts": [["text": text]]])
        }
        if contents.isEmpty {
            contents = [["role": "user", "parts": [["text": systemPrompt]]]]
        }
        // No `responseMimeType: application/json`: chat replies are prose.
        let request = try makeRequest(
            timeout: options.timeout,
            body: [
                "contents": contents,
                "generationConfig": ["maxOutputTokens": options.maxOutputTokens]
            ]
        )

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.textResult(
            from: data,
            as: GeminiResponse.self,
            emptyMessage: "empty Gemini response",
            isTruncated: { $0.candidates?.first?.finishReason == "MAX_TOKENS" },
            extractContent: { Self.text(from: $0) }
        )
    }

    // MARK: - Helpers

    /// The `generateContent` route for the configured model. Gemini model IDs are
    /// sometimes stored with a `models/` prefix already attached, so strip it
    /// rather than emit `models/models/…`.
    private var generateContentPath: String {
        "models/\(model.replacingOccurrences(of: "models/", with: "")):generateContent"
    }

    /// A `generateContent` request with Gemini's API-key header.
    private func makeRequest(timeout: TimeInterval, body: [String: Any]) throws -> URLRequest {
        try LLMHTTP.jsonRequest(
            provider: provider,
            path: generateContentPath,
            fallbackURL: "https://generativelanguage.googleapis.com/v1beta/\(generateContentPath)",
            timeout: timeout,
            headers: ["x-goog-api-key": apiKey],
            body: body
        )
    }

    private static func text(from response: GeminiResponse) -> String? {
        response.candidates?.first?.content?.parts.compactMap { $0.text }.joined()
    }
}

private struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]?
}

private struct GeminiCandidate: Decodable {
    // Optional: a candidate stopped by MAX_TOKENS or a safety filter can omit
    // the content block entirely, and decoding must still succeed so the
    // truncation check gets a chance to run.
    let content: GeminiContent?
    let finishReason: String?
}

private struct GeminiContent: Decodable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Decodable {
    let text: String?
}

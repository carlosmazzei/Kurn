//
//  AnthropicProvider.swift
//  Kurn
//
//  Anthropic implementation of summary generation via the Messages API
//  (POST /v1/messages). Anthropic has no speech endpoint, so transcription is
//  unsupported and cloud transcription always routes through OpenAI Whisper.
//

import Foundation

struct AnthropicProvider: LLMProvider {
    let provider: AIProvider

    private let apiKey: String
    private let session: URLSession
    private let model: String
    private let apiVersion = "2023-06-01"

    init(provider: AIProvider = .anthropic, apiKey: String, model: String = "claude-3-5-sonnet-latest", session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    // MARK: - Transcription (unsupported)

    func transcribe(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString(
                "error.anthropic_no_transcribe",
                comment: "Anthropic does not support transcription"
            )
        )
    }

    // MARK: - Summary (Messages API)

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "messages")
            ?? URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        // Concatenate all text blocks (there is normally one for JSON output).
        return try LLMHTTP.summaryResult(
            from: data,
            as: MessagesResponse.self,
            emptyMessage: "empty Anthropic response"
        ) { decoded in
            decoded.content
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined()
        }
    }

}

// MARK: - Response shapes

private struct MessagesResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }
    let content: [Block]
}

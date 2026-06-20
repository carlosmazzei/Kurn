//
//  AnthropicProvider.swift
//  MeetSync
//
//  Anthropic implementation of summary generation via the Messages API
//  (POST /v1/messages). Anthropic has no speech endpoint, so transcription is
//  unsupported and cloud transcription always routes through OpenAI Whisper.
//

import Foundation

struct AnthropicProvider: LLMProvider {
    let provider: AIProvider = .anthropic

    private let apiKey: String
    private let session: URLSession
    /// Summary model. Configurable here if you want to move to a newer Opus.
    private let model = "claude-opus-4-6"
    private let apiVersion = "2023-06-01"

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
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
        guard !apiKey.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
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
                ["role": "user", "content": userPrompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try validate(response: response, data: data)

        do {
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            // Concatenate all text blocks (there is normally one for JSON output).
            let text = decoded.content
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined()
            guard !text.isEmpty else {
                throw AppError.decodingError("empty Anthropic response")
            }
            let json = try SummaryJSON.parse(text)
            return SummaryResult(
                content: json.summary,
                actionItems: json.actionItems,
                keyDecisions: json.keyDecisions
            )
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - HTTP helpers

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw AppError.networkError(error)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let message = decodeErrorMessage(data) ?? "request failed"
            throw AppError.apiError(statusCode: http.statusCode, message: message)
        }
    }

    private func decodeErrorMessage(_ data: Data) -> String? {
        struct Envelope: Decodable { struct E: Decodable { let message: String }; let error: E }
        return try? JSONDecoder().decode(Envelope.self, from: data).error.message
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

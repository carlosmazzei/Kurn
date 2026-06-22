//
//  GroqProvider.swift
//  Kurn
//
//  Groq implementation of summary generation. Groq exposes an OpenAI-compatible
//  Chat Completions endpoint, so the request/response shapes mirror OpenAI.
//  Transcription is not wired here (cloud transcription uses OpenAI Whisper).
//

import Foundation

struct GroqProvider: LLMProvider {
    let provider: AIProvider

    private let apiKey: String
    private let session: URLSession
    private let model: String

    init(provider: AIProvider = .groq, apiKey: String, model: String = "llama-3.3-70b-versatile", session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString("error.provider_no_transcribe", comment: "Provider has no transcription")
        )
    }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        guard !apiKey.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }

        let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "chat/completions")
            ?? URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LLMHTTP.send(request, session: session)
        try LLMHTTP.validate(response: response, data: data)

        do {
            let decoded = try JSONDecoder().decode(GroqChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                throw AppError.decodingError("empty Groq response")
            }
            let json = try SummaryJSON.parse(content)
            return SummaryResult(sections: json.summarySections)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }
}

private struct GroqChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

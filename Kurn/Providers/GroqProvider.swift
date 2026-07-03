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

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "chat/completions")
            ?? URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = LLMHTTP.summaryTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": LLMHTTP.summaryMaxOutputTokens,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.summaryResult(
            from: data,
            as: ChatResponse.self,
            emptyMessage: "empty Groq response",
            isTruncated: { $0.isTruncated }
        ) { $0.choices.first?.message.content }
    }
}

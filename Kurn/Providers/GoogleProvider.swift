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
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let cleanModel = model.replacingOccurrences(of: "models/", with: "")
        let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "models/\(cleanModel):generateContent")
            ?? URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(cleanModel):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        // Gemini has no dedicated system role here; fold it into the user turn.
        let combined = "\(systemPrompt)\n\n\(userPrompt)"
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": combined]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "maxOutputTokens": 2000
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.summaryResult(
            from: data,
            as: GeminiResponse.self,
            emptyMessage: "empty Gemini response"
        ) { $0.candidates?.first?.content.parts.compactMap { $0.text }.joined() }
    }
}

private struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]?
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContent
}

private struct GeminiContent: Decodable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Decodable {
    let text: String?
}

//
//  GoogleProvider.swift
//  MeetSync
//
//  Google Gemini implementation of summary generation via the Generative
//  Language API (models/{model}:generateContent). Gemini has no speech endpoint
//  wired here, so cloud transcription continues to route through OpenAI Whisper.
//

import Foundation

struct GoogleProvider: LLMProvider {
    let provider: AIProvider = .google

    private let apiKey: String
    private let session: URLSession
    private let model: String

    init(apiKey: String, model: String = "gemini-1.5-pro", session: URLSession = .shared) {
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

        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

        let (data, response) = try await LLMHTTP.send(request, session: session)
        try LLMHTTP.validate(response: response, data: data)

        do {
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            let text = decoded.candidates?.first?.content.parts.compactMap { $0.text }.joined() ?? ""
            guard !text.isEmpty else { throw AppError.decodingError("empty Gemini response") }
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

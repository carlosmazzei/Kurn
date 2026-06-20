//
//  OpenAIProvider.swift
//  MeetSync
//
//  OpenAI implementation: Whisper for transcription (multipart upload,
//  verbose_json for segment timestamps) and Chat Completions (gpt-4o, JSON mode)
//  for summaries. All requests use URLSession with async/await.
//

import Foundation

struct OpenAIProvider: LLMProvider {
    let provider: AIProvider = .openAI

    private let apiKey: String
    private let session: URLSession
    private let chatModel = "gpt-4o"
    private let whisperModel = "whisper-1"

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Transcription (Whisper)

    func transcribe(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        guard !apiKey.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }

        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var fields: [(name: String, value: String)] = [
            ("model", whisperModel),
            ("response_format", "verbose_json"),
        ]
        if let code = language.whisperCode {
            fields.append(("language", code))
        }

        request.httpBody = multipartBody(
            boundary: boundary,
            fields: fields,
            fileField: "file",
            fileName: fileName,
            fileData: audioData,
            mimeType: "audio/m4a"
        )

        let (data, response) = try await send(request)
        try Self.validate(response: response, data: data)

        do {
            let decoded = try JSONDecoder().decode(WhisperVerboseResponse.self, from: data)
            let spans: [TranscribedSpan]
            if let segments = decoded.segments, !segments.isEmpty {
                spans = segments.map {
                    TranscribedSpan(text: $0.text.trimmingCharacters(in: .whitespaces),
                                    start: $0.start,
                                    end: $0.end,
                                    confidence: nil)
                }
            } else {
                // Fallback: one span for the whole blob.
                spans = [TranscribedSpan(text: decoded.text, start: 0, end: 0, confidence: nil)]
            }
            return RawTranscript(spans: spans, language: decoded.language ?? "")
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Summary (Chat Completions)

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        guard !apiKey.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": chatModel,
            "max_tokens": 2000,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try Self.validate(response: response, data: data)

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                throw AppError.decodingError("empty chat response")
            }
            let json = try SummaryJSON.parse(content)
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

    /// Validate status code, extracting OpenAI's `{ "error": { "message" } }`.
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

    private func multipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        fileField: String,
        fileName: String,
        fileData: Data,
        mimeType: String
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for field in fields {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(field.name)\"\(lineBreak)\(lineBreak)")
            body.append("\(field.value)\(lineBreak)")
        }

        body.append("--\(boundary)\(lineBreak)")
        body.append(
            "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\(lineBreak)"
        )
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")
        return body
    }
}

// MARK: - Response shapes

private struct WhisperVerboseResponse: Decodable {
    struct Segment: Decodable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }
    let text: String
    let language: String?
    let segments: [Segment]?
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

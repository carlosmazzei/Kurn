//
//  OpenAIProvider.swift
//  Kurn
//
//  OpenAI implementation: Whisper for transcription (multipart upload,
//  verbose_json for segment timestamps) and Chat Completions (gpt-4o, JSON mode)
//  for summaries. All requests use URLSession with async/await.
//

import Foundation

struct OpenAIProvider: LLMProvider {
    let provider: AIProvider

    private let apiKey: String
    private let session: URLSession
    private let chatModel: String
    private let whisperModel = "whisper-1"
    /// Route transcription uploads through the background `URLSession`
    /// (`WhisperBackgroundUploader`) so they survive the app suspending or the
    /// phone locking. Off by default so injected-session tests and summary
    /// calls are unaffected; `ProviderFactory.whisperProvider()` turns it on.
    private let usesBackgroundUploads: Bool

    init(
        provider: AIProvider = .openAI,
        apiKey: String,
        model: String = "gpt-5.4",
        session: URLSession = .shared,
        usesBackgroundUploads: Bool = false
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.chatModel = model
        self.session = session
        self.usesBackgroundUploads = usesBackgroundUploads
    }

    // MARK: - Transcription (Whisper)

    func transcribe(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // URLSession.shared's default (60s) is tuned for small JSON calls, not a
        // multi-MB audio upload plus Whisper's server-side processing time —
        // AudioChunker caps chunks at 10 minutes of audio, and transcribing that
        // alone can take longer than 60s under load. 300s leaves comfortable headroom.
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var fields: [(name: String, value: String)] = [
            ("model", whisperModel),
            ("response_format", "verbose_json")
        ]
        if let code = language.whisperCode {
            fields.append(("language", code))
        }

        let body = multipartBody(
            boundary: boundary,
            fields: fields,
            file: MultipartFile(
                field: "file",
                name: fileName,
                data: audioData,
                mimeType: "audio/m4a"
            )
        )

        let data: Data
        if usesBackgroundUploads {
            let result = try await WhisperBackgroundUploader.shared.sendValidated(request, body: body)
            data = result.0
        } else {
            request.httpBody = body
            let result = try await LLMHTTP.sendValidated(request, session: session)
            data = result.0
        }

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
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "chat/completions")
            ?? URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = LLMHTTP.summaryTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": chatModel,
            "max_completion_tokens": LLMHTTP.summaryMaxOutputTokens,
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
            emptyMessage: "empty chat response",
            isTruncated: { $0.isTruncated }
        ) { $0.choices.first?.message.content }
    }

    // MARK: - HTTP helpers

    private func multipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        file: MultipartFile
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
            "Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\(lineBreak)"
        )
        body.append("Content-Type: \(file.mimeType)\(lineBreak)\(lineBreak)")
        body.append(file.data)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")
        return body
    }
}

// MARK: - Response shapes

private struct MultipartFile {
    let field: String
    let name: String
    let data: Data
    let mimeType: String
}

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

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

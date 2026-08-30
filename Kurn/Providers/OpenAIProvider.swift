//
//  OpenAIProvider.swift
//  Kurn
//
//  OpenAI implementation: Whisper for transcription (multipart upload,
//  verbose_json for segment timestamps) and Chat Completions (gpt-4o, JSON mode)
//  for summaries. All requests use URLSession with async/await.
//

import Foundation
import KurnCore

struct OpenAIProvider: LLMProvider {
    let provider: AIProvider

    private let apiKey: String
    private let session: URLSession
    private let chatModel: String
    /// Whisper model requested on the transcription route. Configurable because
    /// the model differs per vendor (OpenAI `whisper-1`, Groq `whisper-large-v3`).
    private let transcriptionModel: String
    init(
        provider: AIProvider = .openAI,
        apiKey: String,
        model: String = "gpt-5.4",
        transcriptionModel: String = "whisper-1",
        session: URLSession = .shared
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.chatModel = model
        self.transcriptionModel = transcriptionModel
        self.session = session
    }

    // MARK: - Transcription (Whisper)

    func transcribe(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let url = try LLMHTTP.requireEndpoint(provider: provider, path: "audio/transcriptions")
        AppLog.transcription.atInfo.info("OpenAIProvider: transcribing \(audioData.count, privacy: .public) bytes via \(provider.displayName, privacy: .public), model=\(transcriptionModel, privacy: .public)")

        do {
            let data = try await send(
                audioData: audioData,
                fileName: fileName,
                language: language,
                url: url,
                wordTimestamps: true
            )
            return try Self.transcript(from: data, provider: provider)
        } catch let AppError.apiError(status, _) where status == 400 || status == 422 {
            // `timestamp_granularities[]` is an OpenAI extension, and an
            // OpenAI-*compatible* endpoint is under no obligation to know it.
            // Rejecting the parameter must cost word timings, not the
            // transcription — so drop it and ask once more. Only the two codes a
            // vendor uses for "I don't know that parameter" retry: a 401 is a bad
            // key and retrying it is just a second failure.
            AppLog.transcription.atNotice.notice("OpenAIProvider: \(provider.displayName, privacy: .public) rejected word timestamps (HTTP \(status, privacy: .public)); retrying without them")
            let data = try await send(
                audioData: audioData,
                fileName: fileName,
                language: language,
                url: url,
                wordTimestamps: false
            )
            return try Self.transcript(from: data, provider: provider)
        }
    }

    private func send(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage,
        url: URL,
        wordTimestamps: Bool
    ) async throws -> Data {
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
            ("model", transcriptionModel),
            ("response_format", "verbose_json")
        ]
        if let code = language.whisperCode {
            fields.append(("language", code))
        }
        if wordTimestamps {
            // A repeated field name is how a multipart array is expressed.
            // `segment` has to be asked for explicitly: naming any granularity
            // replaces the default rather than adding to it, and the segment
            // objects are where the quality signals live.
            fields.append(("timestamp_granularities[]", "segment"))
            fields.append(("timestamp_granularities[]", "word"))
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

        do {
            request.httpBody = body
            return try await LLMHTTP.sendValidated(
                request,
                session: session,
                policy: .automated(totalDeadline: request.timeoutInterval)
            ).0
        } catch {
            AppLog.transcription.atError.error("OpenAIProvider: transcription request failed for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Decode one `verbose_json` body into spans. `static` so it is reachable
    /// from tests with a captured response and no network.
    static func transcript(from data: Data, provider: AIProvider) throws -> RawTranscript {
        do {
            let decoded = try JSONDecoder().decode(WhisperVerboseResponse.self, from: data)
            let spans: [TranscribedSpan]
            if let segments = decoded.segments, !segments.isEmpty {
                // `verbose_json` carries the decoder's own confidence signals per
                // segment; they are the only way to tell an invented sentence
                // from a real one, since both read as fluent prose.
                //
                // Words arrive in a flat top-level array, not inside the segments,
                // so they are grouped back under the segment they fall in. Going
                // straight from the flat array to spans would be simpler and would
                // quietly bypass the filter — the words of a hallucinated segment
                // are exactly as invented as the segment.
                spans = TranscriptQualityFilter.keeping(
                    segments.map { segment in
                        TranscriptQualityFilter.ScoredSpan(
                            span: TranscribedSpan(
                                text: segment.text.trimmingCharacters(in: .whitespaces),
                                start: segment.start,
                                end: segment.end,
                                confidence: nil
                            ),
                            quality: SpanQuality(
                                averageLogProb: segment.avgLogprob,
                                noSpeechProb: segment.noSpeechProb,
                                compressionRatio: segment.compressionRatio
                            ),
                            words: words(decoded.words, within: segment)
                        )
                    },
                    engine: "whisperAPI"
                )
            } else {
                // Fallback: one span for the whole blob.
                spans = [TranscribedSpan(text: decoded.text, start: 0, end: 0, confidence: nil)]
            }
            AppLog.transcription.atInfo.info("OpenAIProvider: transcription succeeded for \(provider.displayName, privacy: .public), spans=\(spans.count, privacy: .public)")
            return RawTranscript(spans: spans, language: decoded.language ?? "")
        } catch {
            AppLog.transcription.atError.error("OpenAIProvider: failed to decode transcription response from \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw AppError.decodingError(error.localizedDescription)
        }
    }

    /// The words belonging to one segment, matched by midpoint so a word
    /// straddling the boundary lands on one side rather than both.
    private static func words(
        _ words: [WhisperVerboseResponse.Word]?,
        within segment: WhisperVerboseResponse.Segment
    ) -> [TimedWord] {
        guard let words, !words.isEmpty else { return [] }
        return words.compactMap { word in
            guard word.start.isFinite, word.end.isFinite, word.end >= word.start else { return nil }
            let midpoint = (word.start + word.end) / 2
            guard midpoint >= segment.start, midpoint <= segment.end else { return nil }
            return TimedWord(text: word.word, start: word.start, end: word.end)
        }
    }

    // MARK: - Summary (Chat Completions)

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        let request = try makeRequest(
            timeout: LLMHTTP.summaryTimeout,
            body: [
                "model": chatModel,
                "max_completion_tokens": LLMHTTP.summaryMaxOutputTokens,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
        )

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.summaryResult(
            from: data,
            as: ChatResponse.self,
            emptyMessage: "empty chat response",
            isTruncated: { $0.isTruncated },
            extractContent: { $0.choices.first?.message.content }
        )
    }

    // MARK: - Chat (Chat Completions, plain text)

    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        var wire: [[String: String]] = [["role": "system", "content": systemPrompt]]
        wire += messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        // No `response_format` here: chat replies are prose, not the summary JSON.
        var body: [String: Any] = [
            "model": chatModel,
            "max_completion_tokens": options.maxOutputTokens,
            "messages": wire
        ]
        // GPT-5's completion budget includes hidden reasoning tokens. For a
        // concise meeting answer, low effort prevents reasoning from consuming
        // the entire budget and leaving `message.content` empty. Keep this
        // OpenAI/GPT-5-specific so compatible vendors are not sent a parameter
        // they may not implement.
        if provider.id == AIProvider.openAI.id,
           chatModel.lowercased().hasPrefix("gpt-5") {
            body["reasoning_effort"] = "low"
        }
        let request = try makeRequest(timeout: options.timeout, body: body)

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        return try LLMHTTP.textResult(
            from: data,
            as: ChatResponse.self,
            emptyMessage: "empty chat response",
            isTruncated: { $0.isTruncated },
            extractContent: {
                let message = $0.choices.first?.message
                return message?.content ?? message?.refusal
            }
        )
    }

    // MARK: - HTTP helpers

    /// A Chat Completions request with OpenAI's bearer auth. The transcription
    /// route builds its own multipart request and uses the bounded foreground
    /// transport with the long-running operation policy.
    private func makeRequest(timeout: TimeInterval, body: [String: Any]) throws -> URLRequest {
        try LLMHTTP.jsonRequest(
            provider: provider,
            path: "chat/completions",
            timeout: timeout,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: body
        )
    }

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

struct WhisperVerboseResponse: Decodable {
    struct Word: Decodable {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Segment: Decodable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        /// Quality signals. Optional because OpenAI-compatible vendors are not
        /// obliged to return them, and a missing one must not fail the decode of
        /// an otherwise good response — `TranscriptQualityFilter` treats absence
        /// as "no evidence" rather than as a failure.
        let avgLogprob: Double?
        let noSpeechProb: Double?
        let compressionRatio: Double?

        enum CodingKeys: String, CodingKey {
            case start, end, text
            case avgLogprob = "avg_logprob"
            case noSpeechProb = "no_speech_prob"
            case compressionRatio = "compression_ratio"
        }
    }
    let text: String
    let language: String?
    let segments: [Segment]?
    /// Flat, whole-response list — the API does not nest words inside their
    /// segment. Absent unless `timestamp_granularities[]=word` was accepted.
    let words: [Word]?
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

//
//  ElevenLabsProvider.swift
//  Kurn
//
//  ElevenLabs: transcription-only vendor (Scribe speech-to-text). Conforms to
//  `LLMProvider` like every other cloud vendor so it plugs into the same
//  `ProviderFactory`/Settings/consent machinery as OpenAI, Groq, Anthropic and
//  Google — `AIProviderKind.elevenLabs`/`AIProvider.supportsTranscription`
//  is what makes it selectable in the transcription-provider picker, and
//  `AIProvider.supportsSummarization == false` is what keeps it out of the
//  summary-provider picker. `summarize`/`chat` throw
//  `AppError.summarizationUnsupported` rather than being implemented —
//  `streamChat` needs no override, since `LLMProvider`'s own extension falls
//  back to `chat`, which already throws the right error.
//

import Foundation
import KurnCore

struct ElevenLabsProvider: LLMProvider {
    let provider: AIProvider

    private let apiKey: String
    private let session: URLSession
    private let transcriptionModel: String
    private let largeTransferPolicy: LargeTransferPolicy

    init(
        provider: AIProvider = .elevenLabs,
        apiKey: String,
        transcriptionModel: String = "scribe_v1",
        session: URLSession = .shared,
        largeTransferPolicy: LargeTransferPolicy = .wifiOnly
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.transcriptionModel = transcriptionModel
        self.session = session
        self.largeTransferPolicy = largeTransferPolicy
    }

    // MARK: - Transcription (Scribe)

    func transcribe(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)
        let url = try LLMHTTP.requireEndpoint(provider: provider, path: "speech-to-text")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = LLMHTTP.transcriptionTimeout
        // ElevenLabs uses its own header, not `Authorization: Bearer` — the
        // one real divergence from the OpenAI-compatible Whisper route.
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var fields: [(name: String, value: String)] = [
            ("model_id", transcriptionModel),
            ("diarize", "true")
        ]
        if let code = language.whisperCode {
            fields.append(("language_code", code))
        }
        // Diarization is always requested: it costs nothing extra to ask for,
        // and whether it's actually *used* (vs. the app's own diarizers) is
        // decided independently by `DiarizationEngine.transcriptionProviderNative`
        // — see `RawTranscript.speakerTurns` and
        // `TranscriptionService.nativeDiarizationOutcome`.

        request.httpBody = multipartBody(
            boundary: boundary,
            fields: fields,
            file: MultipartFile(field: "file", name: fileName, data: audioData, mimeType: "audio/m4a")
        )
        largeTransferPolicy.apply(to: &request)

        AppLog.transcription.atInfo.info("ElevenLabsProvider: transcribing \(audioData.count, privacy: .public) bytes via \(provider.displayName, privacy: .public), model=\(transcriptionModel, privacy: .public)")

        let data: Data
        do {
            data = try await LLMHTTP.sendValidated(
                request,
                session: session,
                policy: .automated(totalDeadline: request.timeoutInterval)
            ).0
        } catch {
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.transcription.atError.error("ElevenLabsProvider: transcription request failed for \(provider.displayName, privacy: .public) code=\(code, privacy: .public)")
            throw error
        }

        return try Self.transcript(from: data, provider: provider)
    }

    /// Decode one Scribe response into a `RawTranscript`. `static` so it is
    /// reachable from tests with a captured response and no network.
    static func transcript(from data: Data, provider: AIProvider) throws -> RawTranscript {
        do {
            let decoded = try JSONDecoder().decode(ScribeResponse.self, from: data)
            let duration = decoded.audioDurationSecs ?? 0
            let wordEntries = (decoded.words ?? []).filter { $0.type == "word" }
            let words: [TimedWord] = wordEntries.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            let spans = TimedWordSpanBuilder.spans(
                from: words,
                fallbackText: decoded.text,
                duration: duration
            )
            let speakerTurns = Self.speakerTurns(from: wordEntries)
            AppLog.transcription.atInfo.info("ElevenLabsProvider: transcription succeeded for \(provider.displayName, privacy: .public), spans=\(spans.count, privacy: .public), speakerTurns=\(speakerTurns?.count ?? 0, privacy: .public)")
            return RawTranscript(spans: spans, language: decoded.languageCode ?? "", speakerTurns: speakerTurns)
        } catch {
            AppLog.transcription.atError.error("ElevenLabsProvider: failed to decode transcription response from \(provider.displayName, privacy: .public) code=decode_failed")
            throw AppError.decodingError(error.localizedDescription)
        }
    }

    /// Group consecutive same-speaker words into `SpeakerTurn`s, mapping
    /// Scribe's raw `speaker_id` values (e.g. `"speaker_0"`) to the app's own
    /// `"Speaker N"` label convention, numbered by order of first appearance
    /// — the same convention the local diarizers use. Returns `nil` (not an
    /// empty array) when no word carries a `speaker_id`, so callers can tell
    /// "diarization wasn't returned" apart from a genuine zero-turn result.
    private static func speakerTurns(from words: [ScribeResponse.Word]) -> [SpeakerTurn]? {
        guard words.contains(where: { $0.speakerId != nil }) else { return nil }

        var labelsByRawID: [String: String] = [:]
        var turns: [SpeakerTurn] = []
        for word in words {
            let rawID = word.speakerId ?? "unknown"
            let label = labelsByRawID[rawID] ?? {
                let assigned = "Speaker \(labelsByRawID.count + 1)"
                labelsByRawID[rawID] = assigned
                return assigned
            }()
            if var last = turns.last, last.speakerLabel == label {
                last.end = word.end
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(speakerLabel: label, start: word.start, end: word.end))
            }
        }
        return turns
    }

    private func multipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        file: MultipartFile
    ) -> Data {
        var body = Data()
        for field in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(field.value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(file.mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(file.data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    // MARK: - Summarization (unsupported)

    func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
        throw AppError.summarizationUnsupported(provider: provider.displayName)
    }

    func chat(
        systemPrompt: String,
        messages: [ChatMessage],
        options: TextGenerationOptions
    ) async throws -> String {
        throw AppError.summarizationUnsupported(provider: provider.displayName)
    }
}

private struct MultipartFile {
    let field: String
    let name: String
    let data: Data
    let mimeType: String
}

struct ScribeResponse: Decodable {
    struct Word: Decodable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        /// "word", "spacing", or "audio_event" — only "word" entries are kept
        /// for span-building; spacing/event tokens carry no transcript text
        /// worth timestamping on their own.
        let type: String
        /// Present only when diarization was requested and Scribe could
        /// separate speakers (e.g. `"speaker_0"`). `nil` otherwise.
        let speakerId: String?

        enum CodingKeys: String, CodingKey {
            case text, start, end, type
            case speakerId = "speaker_id"
        }
    }

    let text: String
    let languageCode: String?
    let audioDurationSecs: TimeInterval?
    let words: [Word]?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case audioDurationSecs = "audio_duration_secs"
        case words
    }
}

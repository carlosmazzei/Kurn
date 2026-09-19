//
//  ElevenLabsScribeClient.swift
//  Kurn
//
//  ElevenLabs Scribe speech-to-text: a cloud transcription vendor alongside
//  the OpenAI-compatible Whisper route, added for side-by-side accuracy
//  comparison against Parakeet/whisper.cpp/Apple Speech (see
//  docs/pipeline-evaluation.md's alternatives research). Deliberately does
//  NOT conform to `LLMProvider` — Scribe is transcription-only, with its own
//  `xi-api-key` auth header and its own JSON response shape, so it has no
//  chat/summarize capability to implement and does not belong in
//  `AIProviderKind`/`ProviderFactory`.
//

import Foundation
import KurnCore

struct ElevenLabsScribeClient {
    private let apiKey: String
    private let session: URLSession
    private let largeTransferPolicy: LargeTransferPolicy

    /// A private, non-persisted `AIProvider` value used only to reuse
    /// `LLMHTTP`'s validated-base-URL/error-message plumbing (HTTPS-only host
    /// validation, `AppError.noAPIKey`/`.invalidProviderURL` messages). Never
    /// exposed to Settings, `ProviderFactory`, or the summary/chat pickers —
    /// Scribe is a `TranscriptionEngine`, not a selectable `AIProvider`.
    private static let pseudoProvider = AIProvider(
        id: "elevenLabsScribe",
        displayName: "ElevenLabs",
        kind: .openAICompatible,
        baseURLString: "https://api.elevenlabs.io/v1"
    )

    /// The one Scribe model this integration targets. `scribe_v1` is
    /// ElevenLabs' broadly available, GA speech-to-text model; there is no
    /// model picker in Settings for this engine (see `TranscriptionSettingsView`).
    private static let modelID = "scribe_v1"

    init(
        apiKey: String,
        session: URLSession = .shared,
        largeTransferPolicy: LargeTransferPolicy = .wifiOnly
    ) {
        self.apiKey = apiKey
        self.session = session
        self.largeTransferPolicy = largeTransferPolicy
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        try LLMHTTP.requireAPIKey(apiKey, provider: Self.pseudoProvider)
        let url = try LLMHTTP.requireEndpoint(provider: Self.pseudoProvider, path: "speech-to-text")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = LLMHTTP.transcriptionTimeout
        // ElevenLabs uses its own header, not `Authorization: Bearer` — the
        // one real divergence from the OpenAI-compatible Whisper route that
        // keeps this from reusing `OpenAIProvider` directly.
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var fields: [(name: String, value: String)] = [("model_id", Self.modelID)]
        if let code = language.whisperCode {
            fields.append(("language_code", code))
        }
        // Diarization is deliberately left off: the app's own diarizer +
        // `TranscriptFusion` already attributes speakers independently, and
        // merging two diarization sources is out of scope for this first cut.

        request.httpBody = multipartBody(
            boundary: boundary,
            fields: fields,
            file: MultipartFile(field: "file", name: fileName, data: audioData, mimeType: "audio/m4a")
        )
        largeTransferPolicy.apply(to: &request)

        AppLog.transcription.atInfo.info("ElevenLabsScribeClient: transcribing \(audioData.count, privacy: .public) bytes, model=\(Self.modelID, privacy: .public)")

        let data: Data
        do {
            data = try await LLMHTTP.sendValidated(
                request,
                session: session,
                policy: .automated(totalDeadline: request.timeoutInterval)
            ).0
        } catch {
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.transcription.atError.error("ElevenLabsScribeClient: transcription request failed code=\(code, privacy: .public)")
            throw error
        }

        return try Self.transcript(from: data)
    }

    /// Decode one Scribe response into a `RawTranscript`. `static` so it is
    /// reachable from tests with a captured response and no network.
    static func transcript(from data: Data) throws -> RawTranscript {
        do {
            let decoded = try JSONDecoder().decode(ScribeResponse.self, from: data)
            let duration = decoded.audioDurationSecs ?? 0
            let words: [TimedWord] = (decoded.words ?? [])
                .filter { $0.type == "word" }
                .map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            let spans = TimedWordSpanBuilder.spans(
                from: words,
                fallbackText: decoded.text,
                duration: duration
            )
            AppLog.transcription.atInfo.info("ElevenLabsScribeClient: transcription succeeded, spans=\(spans.count, privacy: .public)")
            return RawTranscript(spans: spans, language: decoded.languageCode ?? "")
        } catch {
            AppLog.transcription.atError.error("ElevenLabsScribeClient: failed to decode transcription response code=decode_failed")
            throw AppError.decodingError(error.localizedDescription)
        }
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

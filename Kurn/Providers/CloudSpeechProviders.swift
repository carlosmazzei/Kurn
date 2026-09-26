//
//  CloudSpeechProviders.swift
//  Kurn
//
//  The three cloud text-to-speech wire formats. Each builds its request in a
//  `static` function so tests can assert the exact URL, headers and body with
//  no network, and each returns bytes `AVAudioPlayer(data:)` opens directly —
//  audio stays in memory and is never written to a file, because it is as
//  meeting-derived as the summary text it speaks (see "Secure local storage"
//  in CLAUDE.md: no transcript-derived content in loose files).
//

import Foundation
import KurnCore

// MARK: - OpenAI-compatible (`/audio/speech`)

struct OpenAISpeechProvider: SpeechSynthesisProvider {
    let provider: AIProvider
    let apiKey: String
    let model: String
    let voice: String
    var session: URLSession = .shared

    var maxCharactersPerRequest: Int { provider.maxSpeechCharacters }

    func synthesize(_ text: String, languageCode: String?) async throws -> Data {
        let request = try Self.request(provider: provider, apiKey: apiKey, model: model, voice: voice, text: text)
        let (data, response) = try await LLMHTTP.sendSpeechRequest(request, session: session)
        return try LLMHTTP.requireAudio(data, response: response)
    }

    /// Groq's speech route only emits WAV; everyone else gets MP3, a tenth of
    /// the size for the same speech.
    static func request(provider: AIProvider, apiKey: String, model: String, voice: String, text: String) throws -> URLRequest {
        let format = provider.id == AIProvider.groq.id ? "wav" : "mp3"
        return try LLMHTTP.jsonRequest(
            provider: provider,
            path: "audio/speech",
            timeout: LLMHTTP.speechTimeout,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: [
                "model": model,
                "voice": voice,
                "input": text,
                "response_format": format
            ]
        )
    }
}

// MARK: - ElevenLabs (`/text-to-speech/{voice_id}`)

struct ElevenLabsSpeechProvider: SpeechSynthesisProvider {
    let provider: AIProvider
    let apiKey: String
    let model: String
    let voice: String
    var session: URLSession = .shared

    var maxCharactersPerRequest: Int { provider.maxSpeechCharacters }

    func synthesize(_ text: String, languageCode: String?) async throws -> Data {
        let request = try Self.request(
            provider: provider, apiKey: apiKey, model: model, voice: voice,
            text: text, languageCode: languageCode
        )
        let (data, response) = try await LLMHTTP.sendSpeechRequest(request, session: session)
        return try LLMHTTP.requireAudio(data, response: response)
    }

    static func request(
        provider: AIProvider,
        apiKey: String,
        model: String,
        voice: String,
        text: String,
        languageCode: String?
    ) throws -> URLRequest {
        // The voice id becomes a path segment; anything but an opaque id would
        // change which endpoint is called.
        guard !voice.isEmpty, voice.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw AppError.speechSynthesisFailed(
                NSLocalizedString("read_aloud.error.invalid_voice", comment: "Voice id is not valid")
            )
        }
        var body: [String: Any] = ["text": text, "model_id": model]
        // Only the v2.5 models accept a language hint; the others reject a
        // request that carries one.
        if let languageCode, model.contains("v2_5") {
            body["language_code"] = languageCode
        }
        return try LLMHTTP.jsonRequest(
            provider: provider,
            path: "text-to-speech/\(voice)",
            timeout: LLMHTTP.speechTimeout,
            headers: ["xi-api-key": apiKey, "Accept": "audio/mpeg"],
            queryItems: [URLQueryItem(name: "output_format", value: "mp3_44100_128")],
            body: body
        )
    }
}

// MARK: - Gemini (`generateContent` with an AUDIO modality)

struct GeminiSpeechProvider: SpeechSynthesisProvider {
    let provider: AIProvider
    let apiKey: String
    let model: String
    let voice: String
    var session: URLSession = .shared

    /// What Gemini's TTS models emit when the MIME type names no rate.
    static let defaultSampleRate = 24_000

    var maxCharactersPerRequest: Int { provider.maxSpeechCharacters }

    func synthesize(_ text: String, languageCode: String?) async throws -> Data {
        let request = try Self.request(provider: provider, apiKey: apiKey, model: model, voice: voice, text: text)
        let (data, _) = try await LLMHTTP.sendSpeechRequest(request, session: session)
        return try Self.audio(from: data)
    }

    static func request(provider: AIProvider, apiKey: String, model: String, voice: String, text: String) throws -> URLRequest {
        let modelPath = model.replacingOccurrences(of: "models/", with: "")
        return try LLMHTTP.jsonRequest(
            provider: provider,
            path: "models/\(modelPath):generateContent",
            timeout: LLMHTTP.speechTimeout,
            headers: ["x-goog-api-key": apiKey],
            body: [
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]
                    ]
                ]
            ]
        )
    }

    /// Decode the base64 PCM from the first audio part and wrap it in a WAVE
    /// header so `AVAudioPlayer` can open it.
    static func audio(from data: Data) throws -> Data {
        let response: GeminiSpeechResponse
        do {
            response = try JSONDecoder().decode(GeminiSpeechResponse.self, from: data)
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
        let parts = response.candidates?.first?.content?.parts ?? []
        guard let inline = parts.lazy.compactMap(\.inlineData).first,
              let pcm = Data(base64Encoded: inline.data),
              !pcm.isEmpty else {
            throw AppError.speechSynthesisFailed(
                NSLocalizedString("read_aloud.error.no_audio", comment: "Provider returned no audio")
            )
        }
        let rate = PCMWaveFile.sampleRate(fromMimeType: inline.mimeType ?? "") ?? defaultSampleRate
        return PCMWaveFile.wrap(pcm: pcm, sampleRate: rate)
    }
}

private struct GeminiSpeechResponse: Decodable {
    struct Candidate: Decodable { let content: Content? }
    struct Content: Decodable { let parts: [Part]? }
    struct Part: Decodable { let inlineData: InlineData? }
    struct InlineData: Decodable {
        let mimeType: String?
        let data: String
    }

    let candidates: [Candidate]?
}

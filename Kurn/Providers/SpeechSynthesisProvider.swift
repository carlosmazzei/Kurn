//
//  SpeechSynthesisProvider.swift
//  Kurn
//
//  Cloud text-to-speech, kept apart from `LLMProvider` on purpose: that
//  protocol is about producing *text* (transcripts, summaries, chat), and a
//  speech vendor shares nothing with it but the key and the base URL. A
//  separate seam also keeps ElevenLabs — transcription-only as an
//  `LLMProvider` — from gaining a `summarize` it cannot serve.
//
//  The on-device voice (`AVSpeechSynthesizer`) is not a conformer: it plays
//  directly rather than returning audio, so `ReadAloudController` drives it
//  through `SystemSpeechEngine` instead.
//

import Foundation
import KurnCore

protocol SpeechSynthesisProvider: Sendable {
    var provider: AIProvider { get }

    /// Longest text one `synthesize` call accepts; callers chunk to this.
    var maxCharactersPerRequest: Int { get }

    /// Encoded audio (MP3 or WAV) for `text`, playable by `AVAudioPlayer(data:)`.
    /// `languageCode` is the ISO 639-1 language detected in the text, for the
    /// vendors that accept a hint; `nil` when detection was not confident.
    func synthesize(_ text: String, languageCode: String?) async throws -> Data
}

extension ProviderFactory {
    /// Build the cloud speech provider for `provider`. Throws `.noAPIKey` when
    /// no key is stored, like every other cloud factory here. Never called for
    /// the on-device provider, which has no network speech route.
    static func speechProvider(
        for provider: AIProvider,
        model: String,
        voice: String
    ) throws -> any SpeechSynthesisProvider {
        guard LLMHTTP.isValidBaseURL(provider.baseURLString) else {
            throw AppError.invalidProviderURL
        }
        let key = KeychainManager.shared.value(for: provider.keychainAccount) ?? ""
        do {
            try LLMHTTP.requireAPIKey(key, provider: provider)
        } catch {
            AppLog.generation.atError.error("ProviderFactory: missing API key for speech provider \(provider.displayName, privacy: .public)")
            throw error
        }
        let resolvedModel = model.isEmpty ? provider.defaultSpeechModel : model
        let resolvedVoice = voice.isEmpty ? provider.defaultSpeechVoice : voice
        AppLog.generation.atInfo.info("ProviderFactory: using \(provider.displayName, privacy: .public) for read aloud, model=\(resolvedModel, privacy: .public)")
        switch provider.speechSynthesisAPI {
        case .openAISpeech:
            return OpenAISpeechProvider(provider: provider, apiKey: key, model: resolvedModel, voice: resolvedVoice)
        case .elevenLabs:
            return ElevenLabsSpeechProvider(provider: provider, apiKey: key, model: resolvedModel, voice: resolvedVoice)
        case .geminiTTS:
            return GeminiSpeechProvider(provider: provider, apiKey: key, model: resolvedModel, voice: resolvedVoice)
        case .system, nil:
            throw AppError.speechSynthesisFailed(
                String(format: NSLocalizedString("read_aloud.error.unsupported", comment: "Provider cannot read aloud"), provider.displayName)
            )
        }
    }
}

extension LLMHTTP {
    /// A spoken paragraph is short to generate but the reply is audio, so the
    /// budget sits between chat and a full summary.
    static let speechTimeout: TimeInterval = 90

    /// Send a speech request. Replaying one has no side effect beyond cost, so
    /// it is marked idempotent: a timed-out request is retried rather than
    /// surfaced as `.ambiguousProviderResult`.
    static func sendSpeechRequest(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await sendValidated(
            request,
            session: session,
            policy: .interactive(totalDeadline: speechTimeout),
            context: HTTPExecutionContext(semantics: HTTPRequestSemantics(replaySafety: .idempotent))
        )
    }

    /// Reject a 2xx reply that is not audio — a proxy's HTML page or a JSON
    /// error body some vendors send with 200 — before `AVAudioPlayer` turns it
    /// into an opaque OSStatus.
    static func requireAudio(_ data: Data, response: URLResponse) throws -> Data {
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        let isTextual = contentType.hasPrefix("application/json") || contentType.hasPrefix("text/")
        guard !data.isEmpty, !isTextual else {
            throw AppError.speechSynthesisFailed(
                NSLocalizedString("read_aloud.error.no_audio", comment: "Provider returned no audio")
            )
        }
        return data
    }
}

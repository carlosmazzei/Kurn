//
//  SpeechSynthesisTests.swift
//  KurnTests
//
//  The read-aloud feature's provider seam, with no network: which providers can
//  speak, the exact request each wire format sends, how Gemini's bare PCM is
//  made playable, and that stored preferences survive missing fields. Playback
//  itself (`AVSpeechSynthesizer`, `AVAudioPlayer`, the Lock Screen) cannot be
//  exercised by a test host and stays device-verified.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct SpeechSynthesisTests {

    // MARK: - Catalog

    @Test func everyKindButAnthropicCanSpeak() {
        #expect(AIProvider.appleOnDevice.speechSynthesisAPI == .system)
        #expect(AIProvider.openAI.speechSynthesisAPI == .openAISpeech)
        #expect(AIProvider.groq.speechSynthesisAPI == .openAISpeech)
        #expect(AIProvider.elevenLabs.speechSynthesisAPI == .elevenLabs)
        #expect(AIProvider.google.speechSynthesisAPI == .geminiTTS)
        #expect(AIProvider.anthropic.speechSynthesisAPI == nil)
        #expect(!AIProvider.anthropic.isUsableForSpeech)
    }

    @Test func onDeviceVoiceNeedsNoKey() {
        #expect(AIProvider.appleOnDevice.isUsableForSpeech)
    }

    @Test func groqIsLimitedToItsOwnModelsAndShortRequests() {
        #expect(AIProvider.groq.maxSpeechCharacters == 200)
        #expect(AIProvider.groq.defaultSpeechModel.hasPrefix("canopylabs/orpheus"))
        #expect(AIProvider.openAI.maxSpeechCharacters <= 4_096)
    }

    @Test func cloudProvidersHaveDefaults() {
        for provider in [AIProvider.openAI, .groq, .elevenLabs, .google] {
            #expect(!provider.defaultSpeechModel.isEmpty)
            #expect(!provider.defaultSpeechVoice.isEmpty)
            #expect(provider.suggestedSpeechModels.contains(provider.defaultSpeechModel))
        }
        #expect(AIProvider.appleOnDevice.defaultSpeechVoice.isEmpty)
    }

    // MARK: - Preferences

    @Test func preferencesDefaultToOnDevice() {
        let preferences = ReadAloudPreferences()
        #expect(preferences.providerID == AIProvider.appleOnDevice.id)
        #expect(preferences.rate == 1.0)
    }

    @Test func preferencesFallBackToProviderDefaults() {
        var preferences = ReadAloudPreferences()
        #expect(preferences.voice(for: .openAI) == AIProvider.openAI.defaultSpeechVoice)
        preferences.voices[AIProvider.openAI.id] = "  "
        #expect(preferences.voice(for: .openAI) == AIProvider.openAI.defaultSpeechVoice)
        preferences.voices[AIProvider.openAI.id] = "nova"
        preferences.models[AIProvider.openAI.id] = "tts-1"
        #expect(preferences.voice(for: .openAI) == "nova")
        #expect(preferences.model(for: .openAI) == "tts-1")
        #expect(preferences.model(for: .google) == AIProvider.google.defaultSpeechModel)
    }

    @Test func preferencesDecodeWithMissingFields() throws {
        let decoded = try JSONDecoder().decode(
            ReadAloudPreferences.self,
            from: Data(#"{"providerID":"openAI"}"#.utf8)
        )
        #expect(decoded.providerID == "openAI")
        #expect(decoded.voices.isEmpty)
        #expect(decoded.rate == 1.0)
    }

    @Test func preferencesRoundTrip() throws {
        var preferences = ReadAloudPreferences()
        preferences.providerID = AIProvider.elevenLabs.id
        preferences.voices[AIProvider.elevenLabs.id] = "abc123"
        preferences.rate = 1.5
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(ReadAloudPreferences.self, from: data) == preferences)
    }

    // MARK: - Requests

    @Test func openAIRequestShape() throws {
        let request = try OpenAISpeechProvider.request(
            provider: .openAI, apiKey: "sk-test", model: "gpt-4o-mini-tts", voice: "nova", text: "Hello."
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try Self.json(request)
        #expect(body["model"] as? String == "gpt-4o-mini-tts")
        #expect(body["voice"] as? String == "nova")
        #expect(body["input"] as? String == "Hello.")
        #expect(body["response_format"] as? String == "mp3")
    }

    @Test func groqRequestsWAV() throws {
        let request = try OpenAISpeechProvider.request(
            provider: .groq, apiKey: "gsk", model: "canopylabs/orpheus-v1-english", voice: "troy", text: "Hi."
        )
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/speech")
        #expect(try Self.json(request)["response_format"] as? String == "wav")
    }

    @Test func elevenLabsRequestShape() throws {
        let request = try ElevenLabsSpeechProvider.request(
            provider: .elevenLabs, apiKey: "xi", model: "eleven_multilingual_v2",
            voice: "JBFqnCBsd6RMkjVDRZzb", text: "Olá.", languageCode: "pt"
        )
        #expect(request.url?.absoluteString
            == "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb?output_format=mp3_44100_128")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi")
        let body = try Self.json(request)
        #expect(body["text"] as? String == "Olá.")
        #expect(body["model_id"] as? String == "eleven_multilingual_v2")
        // multilingual v2 rejects a language hint; only v2.5 models get one.
        #expect(body["language_code"] == nil)
    }

    @Test func elevenLabsSendsLanguageHintToV25Models() throws {
        let request = try ElevenLabsSpeechProvider.request(
            provider: .elevenLabs, apiKey: "xi", model: "eleven_flash_v2_5",
            voice: "abc", text: "Olá.", languageCode: "pt"
        )
        #expect(try Self.json(request)["language_code"] as? String == "pt")
    }

    @Test func elevenLabsRejectsVoiceThatWouldChangeThePath() {
        for voice in ["", "../models", "a b", "voice?x=1"] {
            #expect(throws: AppError.self) {
                _ = try ElevenLabsSpeechProvider.request(
                    provider: .elevenLabs, apiKey: "xi", model: "m", voice: voice, text: "t", languageCode: nil
                )
            }
        }
    }

    @Test func geminiRequestShape() throws {
        let request = try GeminiSpeechProvider.request(
            provider: .google, apiKey: "g", model: "gemini-2.5-flash-preview-tts", voice: "Kore", text: "Hallo."
        )
        #expect(request.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g")
        let body = try Self.json(request)
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["responseModalities"] as? [String] == ["AUDIO"])
        let speech = try #require(config["speechConfig"] as? [String: Any])
        let voice = try #require(speech["voiceConfig"] as? [String: Any])
        let prebuilt = try #require(voice["prebuiltVoiceConfig"] as? [String: Any])
        #expect(prebuilt["voiceName"] as? String == "Kore")
    }

    // MARK: - Responses

    @Test func geminiPCMIsWrappedAsWAV() throws {
        let pcm = Data([0, 1, 2, 3, 4, 5])
        let json = """
        {"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"audio/L16;codec=pcm;rate=24000","data":"\(pcm.base64EncodedString())"}}]}}]}
        """
        let audio = try GeminiSpeechProvider.audio(from: Data(json.utf8))
        #expect(audio.count == 44 + pcm.count)
        #expect(String(decoding: audio.prefix(4), as: UTF8.self) == "RIFF")
        #expect(audio.suffix(pcm.count) == pcm)
    }

    @Test func geminiWithoutAudioFails() {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"no audio"}]}}]}"#
        #expect(throws: AppError.self) { _ = try GeminiSpeechProvider.audio(from: Data(json.utf8)) }
    }

    @Test func textualSuccessResponseIsNotAudio() throws {
        let url = try #require(URL(string: "https://api.openai.com/v1/audio/speech"))
        let json = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        ))
        let mpeg = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"]
        ))
        #expect(throws: AppError.self) { _ = try LLMHTTP.requireAudio(Data("{}".utf8), response: json) }
        #expect(throws: AppError.self) { _ = try LLMHTTP.requireAudio(Data(), response: mpeg) }
        #expect(try LLMHTTP.requireAudio(Data([0xFF, 0xFB]), response: mpeg) == Data([0xFF, 0xFB]))
    }

    // MARK: - Helpers

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

@MainActor
struct SystemSpeechEngineTests {
    @Test func rateMappingIsMonotonicAndBounded() {
        let rates = ReadAloudPreferences.rateOptions.map(SystemSpeechEngine.utteranceRate(for:))
        #expect(rates == rates.sorted())
        #expect(SystemSpeechEngine.utteranceRate(for: 1.0) == 0.5)
        #expect(rates.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func detectsDominantLanguage() {
        let portuguese = "A equipe decidiu adiar o lançamento para a próxima semana, depois da revisão do orçamento."
        #expect(SystemSpeechEngine.dominantLanguage(of: portuguese) == "pt")
        #expect(SystemSpeechEngine.dominantLanguage(of: "") == nil)
    }
}

//
//  SpeechSynthesisCatalog.swift
//  Kurn
//
//  Which providers can read text aloud, and with what. Keyed off
//  `AIProviderKind` like the other capability flags (`supportsTranscription`,
//  `supportsSummarization`), so a custom provider of a speaking kind inherits
//  the capability — only Groq, whose OpenAI-compatible speech route serves a
//  different model family with a 200-character request cap, is special-cased
//  by id, the same way `defaultTranscriptionModel` already treats it.
//
//  Voices and models are *suggestions*, not a closed set: vendors add voices
//  far faster than this app ships, so Settings offers these and still accepts
//  anything typed.
//

import Foundation

/// The wire protocol a provider speaks for text-to-speech.
enum SpeechSynthesisAPI: Sendable, Equatable {
    /// `AVSpeechSynthesizer`: on-device, no key, no network.
    case system
    /// `POST /audio/speech` (OpenAI, Groq, custom OpenAI-compatible hosts).
    case openAISpeech
    /// `POST /text-to-speech/{voice_id}` with `xi-api-key`.
    case elevenLabs
    /// `generateContent` with `responseModalities: ["AUDIO"]`, returning PCM.
    case geminiTTS
}

/// One suggested voice. `id` is what the API wants; `name` is what a person
/// reads (ElevenLabs voice ids are opaque, the others are their own names).
struct SpeechVoiceOption: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

extension AIProvider {
    var speechSynthesisAPI: SpeechSynthesisAPI? {
        switch kind {
        case .appleOnDevice: return .system
        case .openAICompatible: return .openAISpeech
        case .elevenLabs: return .elevenLabs
        case .googleGemini: return .geminiTTS
        case .anthropic: return nil
        }
    }

    /// Whether this provider can read text aloud at all.
    var supportsSpeechSynthesis: Bool { speechSynthesisAPI != nil }

    /// Whether this provider can read aloud *right now*. Unlike `isUsable`,
    /// the on-device case does not depend on Apple Intelligence: the system
    /// speech synthesizer exists on every device.
    var isUsableForSpeech: Bool {
        guard let api = speechSynthesisAPI else { return false }
        return api == .system || KeychainManager.shared.hasValue(for: keychainAccount)
    }

    private var isGroq: Bool { id == AIProvider.groq.id }

    var defaultSpeechModel: String {
        switch speechSynthesisAPI {
        case .openAISpeech: return isGroq ? "canopylabs/orpheus-v1-english" : "gpt-4o-mini-tts"
        case .elevenLabs: return "eleven_multilingual_v2"
        case .geminiTTS: return "gemini-2.5-flash-preview-tts"
        case .system, nil: return ""
        }
    }

    var suggestedSpeechModels: [String] {
        switch speechSynthesisAPI {
        case .openAISpeech:
            return isGroq
                ? ["canopylabs/orpheus-v1-english", "canopylabs/orpheus-arabic-saudi"]
                : ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"]
        case .elevenLabs:
            return ["eleven_multilingual_v2", "eleven_flash_v2_5", "eleven_turbo_v2_5", "eleven_v3"]
        case .geminiTTS:
            return ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"]
        case .system, nil:
            return []
        }
    }

    /// Cloud voices to offer. Empty for the system engine, whose installed
    /// voices are only known at runtime (see `ReadAloudSettingsView`).
    var suggestedSpeechVoices: [SpeechVoiceOption] {
        switch speechSynthesisAPI {
        case .openAISpeech:
            let names = isGroq
                ? ["troy", "austin", "daniel", "autumn", "diana", "hannah"]
                : ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
            return names.map { SpeechVoiceOption(id: $0, name: $0.capitalized) }
        case .elevenLabs:
            return [
                SpeechVoiceOption(id: "JBFqnCBsd6RMkjVDRZzb", name: "George"),
                SpeechVoiceOption(id: "21m00Tcm4TlvDq8EwSSP", name: "Rachel"),
                SpeechVoiceOption(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah"),
                SpeechVoiceOption(id: "pNInz6obpgDQGcFmaJgB", name: "Adam"),
                SpeechVoiceOption(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte"),
                SpeechVoiceOption(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel")
            ]
        case .geminiTTS:
            return ["Kore", "Puck", "Zephyr", "Charon", "Fenrir", "Leda", "Orus", "Aoede"]
                .map { SpeechVoiceOption(id: $0, name: $0) }
        case .system, nil:
            return []
        }
    }

    /// Voice used when the user has not picked one. Empty for the system
    /// engine, which then picks a voice matching the text's language.
    var defaultSpeechVoice: String { suggestedSpeechVoices.first?.id ?? "" }

    /// Longest text sent in one request. OpenAI caps `input` at 4096
    /// characters and Groq's Orpheus at 200; Gemini returns uncompressed PCM
    /// inside base64 JSON, so its pieces stay short enough that one response
    /// (~6 MB) sits well under `HTTPPolicy.defaultMaxResponseBytes`. Smaller
    /// pieces also start playing sooner. The system engine takes any length;
    /// its value only sets how finely skip and progress move.
    var maxSpeechCharacters: Int {
        switch speechSynthesisAPI {
        case .openAISpeech: return isGroq ? 200 : 4_000
        case .elevenLabs: return 4_000
        case .geminiTTS: return 1_500
        case .system: return 1_200
        case nil: return 1_200
        }
    }
}

/// The user's read-aloud choices, persisted as one JSON blob in `AppSettings`
/// (like `UsageStats`). Voice and model are remembered per provider, so
/// switching provider and back does not lose a choice made for the first.
struct ReadAloudPreferences: Codable, Equatable, Sendable {
    /// On-device by default: a fresh install never sends text off the device
    /// to be read, and needs no key.
    var providerID: String = AIProvider.appleOnDevice.id
    var voices: [String: String] = [:]
    var models: [String: String] = [:]
    var rate: Float = 1.0

    static let rateOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init() {}

    /// Tolerant decoding: a missing or future field falls back to its default
    /// instead of discarding every other choice with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? AIProvider.appleOnDevice.id
        voices = try container.decodeIfPresent([String: String].self, forKey: .voices) ?? [:]
        models = try container.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? 1.0
    }

    func voice(for provider: AIProvider) -> String {
        let stored = voices[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? provider.defaultSpeechVoice : stored
    }

    func model(for provider: AIProvider) -> String {
        let stored = models[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? provider.defaultSpeechModel : stored
    }
}

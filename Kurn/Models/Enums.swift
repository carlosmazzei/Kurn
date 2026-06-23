//
//  Enums.swift
//  Kurn
//
//  Shared value types used across models, services, and views.
//

import Foundation

/// Lifecycle of a recording's transcription.
enum TranscriptionStatus: String, Codable, Sendable {
    case none
    case inProgress
    case done
    case failed
}

/// Fine-grained stage within an in-progress transcription, surfaced to the UI so
/// the user can see what the app is currently doing (e.g. cleaning audio vs.
/// transcribing). Reported by `TranscriptionService` as it advances.
enum TranscriptionPhase: String, Sendable {
    case preparing
    case preprocessing
    case transcribing
    case finalizing

    /// Short, user-facing description of the current stage.
    var displayName: String {
        switch self {
        case .preparing: return NSLocalizedString("phase.preparing", comment: "Preparing")
        case .preprocessing: return NSLocalizedString("phase.preprocessing", comment: "Cleaning audio")
        case .transcribing: return NSLocalizedString("phase.transcribing", comment: "Transcribing")
        case .finalizing: return NSLocalizedString("phase.finalizing", comment: "Finalizing")
        }
    }
}

/// Microphone pickup pattern preference for the built-in mic.
enum MicPickup: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Omnidirectional: capture the whole room / all participants.
    case wholeRoom
    /// Cardioid (directional): favour the person in front of the device.
    case focusSpeaker

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wholeRoom: return NSLocalizedString("micpickup.whole_room", comment: "Whole room")
        case .focusSpeaker: return NSLocalizedString("micpickup.focus_speaker", comment: "Focus on speaker")
        }
    }
}

/// Recording audio quality, mapped to the encoder bit rate.
enum AudioQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case high
    case standard
    case low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .high: return NSLocalizedString("quality.high", comment: "High")
        case .standard: return NSLocalizedString("quality.standard", comment: "Standard")
        case .low: return NSLocalizedString("quality.low", comment: "Low")
        }
    }

    /// AAC bit rate (bits per second) for the recorder.
    var bitRate: Int {
        switch self {
        case .high: return 128_000
        case .standard: return 64_000
        case .low: return 32_000
        }
    }
}

/// Where a transcript is produced.
enum TranscriptionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case onDevice
    case whisperAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return NSLocalizedString("mode.on_device", comment: "On-device")
        case .whisperAPI: return NSLocalizedString("mode.whisper", comment: "Whisper API")
        }
    }
}

/// Speaker diarization engine used when transcribing a recording.
enum DiarizationEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Pitch/ZCR/spectral-tilt clustering, always available, no downloads.
    case heuristic
    /// FluidAudio's on-device diarization models (downloaded on first use).
    case fluidAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heuristic: return NSLocalizedString("diarization.heuristic", comment: "Heuristic")
        case .fluidAudio: return NSLocalizedString("diarization.fluid_audio", comment: "FluidAudio")
        }
    }
}

/// API shape a configured LLM provider speaks.
enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAICompatible
    case anthropic
    case googleGemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        case .googleGemini: return "Google Gemini"
        }
    }

    var defaultBaseURLString: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

/// Configured LLM provider used for summaries. Built-ins are presets; users can
/// add more providers by choosing an API shape and a base URL.
struct AIProvider: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var kind: AIProviderKind
    var baseURLString: String
    var brandHex: String
    var defaultModel: String
    var isBuiltIn: Bool
    var legacyKeychainAccount: String?

    var rawValue: String { id }

    var keychainAccount: String {
        legacyKeychainAccount ?? "provider_\(id)_api_key"
    }

    static let openAI = AIProvider(
        id: "openAI",
        displayName: "OpenAI",
        kind: .openAICompatible,
        baseURLString: "https://api.openai.com/v1",
        brandHex: "#10A37F",
        defaultModel: "gpt-5.4",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.openAI.rawValue
    )

    static let anthropic = AIProvider(
        id: "anthropic",
        displayName: "Anthropic",
        kind: .anthropic,
        baseURLString: "https://api.anthropic.com/v1",
        brandHex: "#D97757",
        defaultModel: "claude-3-5-sonnet-latest",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.anthropic.rawValue
    )

    static let google = AIProvider(
        id: "google",
        displayName: "Google AI",
        kind: .googleGemini,
        baseURLString: "https://generativelanguage.googleapis.com/v1beta",
        brandHex: "#4285F4",
        defaultModel: "gemini-1.5-pro",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.google.rawValue
    )

    static let groq = AIProvider(
        id: "groq",
        displayName: "Groq",
        kind: .openAICompatible,
        baseURLString: "https://api.groq.com/openai/v1",
        brandHex: "#F55036",
        defaultModel: "llama-3.3-70b-versatile",
        isBuiltIn: true,
        legacyKeychainAccount: KeychainKey.groq.rawValue
    )

    static let defaultProviders: [AIProvider] = [.openAI, .anthropic, .google, .groq]

    init(
        id: String,
        displayName: String,
        kind: AIProviderKind,
        baseURLString: String,
        brandHex: String = "#64748B",
        defaultModel: String = "",
        isBuiltIn: Bool = false,
        legacyKeychainAccount: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURLString = baseURLString
        self.brandHex = brandHex
        self.defaultModel = defaultModel
        self.isBuiltIn = isBuiltIn
        self.legacyKeychainAccount = legacyKeychainAccount
    }

    init?(rawValue: String) {
        if let provider = Self.defaultProviders.first(where: { $0.id == rawValue }) {
            self = provider
        } else {
            self = AIProvider(
                id: rawValue,
                displayName: rawValue,
                kind: .openAICompatible,
                baseURLString: AIProviderKind.openAICompatible.defaultBaseURLString
            )
        }
    }

    static func custom(displayName: String, kind: AIProviderKind, baseURLString: String) -> AIProvider {
        AIProvider(
            id: "custom-\(UUID().uuidString)",
            displayName: displayName,
            kind: kind,
            baseURLString: baseURLString
        )
    }
}

/// One speaker-attributed span of speech. Stored inside `Transcript` as JSON
/// `Data` because SwiftData does not persist arbitrary `Codable` arrays of
/// structs directly.
struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var speakerLabel: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var confidence: Float?

    var duration: TimeInterval { max(0, endTime - startTime) }
}

/// Supported transcription languages, with the BCP-47 locale used for both the
/// on-device recognizer and Whisper hints. `autoDetect` lets the engine decide.
enum MeetingLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case autoDetect
    case portuguese
    case english
    case spanish
    case french
    case german
    case japanese
    case chinese

    var id: String { rawValue }

    /// BCP-47 identifier, or `nil` for auto-detect.
    var localeIdentifier: String? {
        switch self {
        case .autoDetect: return nil
        case .portuguese: return "pt-BR"
        case .english: return "en-US"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .japanese: return "ja-JP"
        case .chinese: return "zh-CN"
        }
    }

    /// Two-letter code Whisper expects in its `language` field, or `nil`.
    var whisperCode: String? {
        guard let id = localeIdentifier else { return nil }
        return String(id.prefix(2))
    }

    var displayName: String {
        switch self {
        case .autoDetect: return NSLocalizedString("lang.auto", comment: "Auto-detect")
        case .portuguese: return NSLocalizedString("lang.pt", comment: "Portuguese")
        case .english: return NSLocalizedString("lang.en", comment: "English")
        case .spanish: return NSLocalizedString("lang.es", comment: "Spanish")
        case .french: return NSLocalizedString("lang.fr", comment: "French")
        case .german: return NSLocalizedString("lang.de", comment: "German")
        case .japanese: return NSLocalizedString("lang.ja", comment: "Japanese")
        case .chinese: return NSLocalizedString("lang.zh", comment: "Chinese")
        }
    }
}

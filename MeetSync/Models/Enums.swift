//
//  Enums.swift
//  MeetSync
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

/// Which LLM vendor generates summaries.
enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case google
    case groq

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google AI"
        case .groq: return "Groq"
        }
    }

    var keychainKey: KeychainKey {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .google: return .google
        case .groq: return .groq
        }
    }

    /// Models the user can pick for summaries, newest/preferred first.
    var availableModels: [String] {
        switch self {
        case .openAI: return ["gpt-5.4", "gpt-4o", "gpt-4o-mini", "gpt-4.1", "o4-mini"]
        case .anthropic: return ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest", "claude-3-opus-latest"]
        case .google: return ["gemini-1.5-pro", "gemini-1.5-flash"]
        case .groq: return ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"]
        }
    }

    var defaultModel: String { availableModels.first ?? "" }

    /// Brand accent used for the provider's icon well in Settings.
    var brandHex: String {
        switch self {
        case .openAI: return "#10A37F"
        case .anthropic: return "#D97757"
        case .google: return "#4285F4"
        case .groq: return "#F55036"
        }
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

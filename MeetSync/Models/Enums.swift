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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var keychainKey: KeychainKey {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
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

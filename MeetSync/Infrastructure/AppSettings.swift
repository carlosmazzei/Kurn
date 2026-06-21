//
//  AppSettings.swift
//  MeetSync
//
//  Observable, UserDefaults-backed app preferences. API keys are NOT stored here
//  — they live in the Keychain (see KeychainManager). Only non-secret defaults
//  belong in this file.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let provider = "settings.aiProvider"
        static let defaultMode = "settings.defaultTranscriptionMode"
        static let defaultLanguage = "settings.defaultLanguage"
        static let micPickup = "settings.micPickup"
        static let audioQuality = "settings.audioQuality"
        static let summaryModels = "settings.summaryModels"
    }

    private let defaults = UserDefaults.standard

    var aiProvider: AIProvider {
        didSet { defaults.set(aiProvider.rawValue, forKey: Keys.provider) }
    }

    var defaultMode: TranscriptionMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Keys.defaultMode) }
    }

    var defaultLanguage: MeetingLanguage {
        didSet { defaults.set(defaultLanguage.rawValue, forKey: Keys.defaultLanguage) }
    }

    /// Built-in microphone pickup preference. Defaults to whole-room capture.
    var micPickup: MicPickup {
        didSet { defaults.set(micPickup.rawValue, forKey: Keys.micPickup) }
    }

    /// Recording audio quality (encoder bit rate). Defaults to high.
    var audioQuality: AudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: Keys.audioQuality) }
    }

    /// Per-provider chosen summary model (rawValue → model id).
    private var summaryModels: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(summaryModels) {
                defaults.set(data, forKey: Keys.summaryModels)
            }
        }
    }

    /// Selected summary model for a provider, falling back to its default.
    func summaryModel(for provider: AIProvider) -> String {
        let stored = summaryModels[provider.rawValue]
        if let stored, provider.availableModels.contains(stored) { return stored }
        return provider.defaultModel
    }

    func setSummaryModel(_ model: String, for provider: AIProvider) {
        summaryModels[provider.rawValue] = model
    }

    init() {
        aiProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? .openAI
        defaultMode = TranscriptionMode(
            rawValue: defaults.string(forKey: Keys.defaultMode) ?? ""
        ) ?? .onDevice
        defaultLanguage = MeetingLanguage(
            rawValue: defaults.string(forKey: Keys.defaultLanguage) ?? ""
        ) ?? .autoDetect
        micPickup = MicPickup(
            rawValue: defaults.string(forKey: Keys.micPickup) ?? ""
        ) ?? .wholeRoom
        audioQuality = AudioQuality(
            rawValue: defaults.string(forKey: Keys.audioQuality) ?? ""
        ) ?? .high
        if let data = defaults.data(forKey: Keys.summaryModels),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            summaryModels = decoded
        } else {
            summaryModels = [:]
        }
    }
}

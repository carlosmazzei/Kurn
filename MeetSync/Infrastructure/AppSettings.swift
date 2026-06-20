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
    }
}

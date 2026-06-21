//
//  AppSettings.swift
//  Kurn
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
        static let providers = "settings.aiProviders"
        static let defaultMode = "settings.defaultTranscriptionMode"
        static let defaultLanguage = "settings.defaultLanguage"
        static let micPickup = "settings.micPickup"
        static let audioQuality = "settings.audioQuality"
        static let summaryModels = "settings.summaryModels"
    }

    private let defaults = UserDefaults.standard

    var providers: [AIProvider] {
        didSet { persistProviders() }
    }

    var aiProviderID: String {
        didSet { defaults.set(aiProviderID, forKey: Keys.provider) }
    }

    var aiProvider: AIProvider {
        providers.first(where: { $0.id == aiProviderID }) ?? providers.first ?? .openAI
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
        if let stored, !stored.isEmpty { return stored }
        return provider.defaultModel
    }

    func setSummaryModel(_ model: String, for provider: AIProvider) {
        summaryModels[provider.rawValue] = model
    }

    func addProvider(_ provider: AIProvider) {
        providers.append(provider)
        aiProviderID = provider.id
    }

    func updateProvider(_ provider: AIProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }

    func removeProvider(_ provider: AIProvider) {
        guard !provider.isBuiltIn else { return }
        providers.removeAll { $0.id == provider.id }
        summaryModels[provider.id] = nil
        KeychainManager.shared.delete(provider.keychainAccount)
        if aiProviderID == provider.id {
            aiProviderID = providers.first?.id ?? AIProvider.openAI.id
        }
    }

    init() {
        let loadedProviders: [AIProvider]
        if let data = defaults.data(forKey: Keys.providers),
           let decoded = try? JSONDecoder().decode([AIProvider].self, from: data),
           !decoded.isEmpty {
            loadedProviders = Self.mergedProviders(decoded)
        } else {
            loadedProviders = AIProvider.defaultProviders
        }
        providers = loadedProviders
        let storedProviderID = defaults.string(forKey: Keys.provider) ?? AIProvider.openAI.id
        aiProviderID = loadedProviders.contains(where: { $0.id == storedProviderID })
            ? storedProviderID
            : AIProvider.openAI.id
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

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Keys.providers)
        }
    }

    private static func mergedProviders(_ stored: [AIProvider]) -> [AIProvider] {
        var providers = AIProvider.defaultProviders
        for provider in stored where !provider.isBuiltIn && !providers.contains(where: { $0.id == provider.id }) {
            providers.append(provider)
        }
        return providers
    }
}

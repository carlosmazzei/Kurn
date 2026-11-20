//
//  AppSettingsCloudConsentTests.swift
//  KurnTests
//
//  The shared cloud-consent ledger: upgrades keep every send already allowed,
//  per-recording features record the automatic grant, and withdrawing it
//  turns those features off.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct AppSettingsCloudConsentTests {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "kurn-consent-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func aFreshInstallAllowsNoCloudProvider() {
        let settings = MeetingFixtures.isolatedSettings()
        #expect(settings.cloudConsents.destinations.isEmpty)
        #expect(!settings.allowsCloud(.openAI, for: .onRequest))
        #expect(settings.allowsCloud(.appleOnDevice, for: .automatic))
    }

    @Test func upgradingKeepsCloudTranscriptionConsent() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let destination = CloudConsentLedger.destination(providerID: AIProvider.openAI.id,
                                                         endpoint: AIProvider.openAI.baseURLString)
        defaults.set([destination], forKey: AppSettings.Keys.cloudTranscriptionConsentKeys)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.hasCloudTranscriptionConsent(for: .openAI))
        #expect(settings.cloudConsents.allows(destination, for: .automatic))
    }

    @Test func migrationRunsOnce() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let destination = settings.cloudConsentDestination(for: .openAI)
        defaults.set([destination], forKey: AppSettings.Keys.cloudTranscriptionConsentKeys)
        #expect(!AppSettings(defaults: defaults).cloudConsents.allows(destination, for: .automatic))
    }

    /// Isolated settings start on the exempt on-device provider; these tests
    /// need a cloud one so every grant assertion runs.
    private func cloudSettings() -> AppSettings {
        let settings = MeetingFixtures.isolatedSettings()
        settings.aiProviderID = AIProvider.openAI.id
        return settings
    }

    @Test func choosingACloudSummaryProviderGrantsOnRequestOnly() {
        let settings = cloudSettings()
        #expect(settings.aiProvider == .openAI)
        #expect(settings.allowsCloud(.openAI, for: .onRequest))
        #expect(!settings.allowsCloud(.openAI, for: .automatic))
    }

    @Test func enablingTheWikiGrantsAutomaticSendingToTheSummaryProvider() {
        let settings = cloudSettings()
        settings.wikiEnabled = true
        #expect(settings.allowsCloud(.openAI, for: .automatic))
        #expect(settings.wikiAutomaticAllowed)
    }

    @Test func aTextGrantNeverAuthorizesAnAudioUpload() {
        let settings = cloudSettings()
        settings.aiTitleCloudEnabled = true
        #expect(settings.allowsCloud(.openAI, for: .automatic))
        #expect(!settings.hasCloudTranscriptionConsent(for: .openAI))
    }

    @Test func switchingSummaryProvidersDoesNotCarryTheAutomaticGrant() {
        let settings = cloudSettings()
        settings.wikiEnabled = true
        let other = AIProvider(id: "other-test", displayName: "Other", kind: .openAICompatible,
                               baseURLString: "https://other.example.com/v1")
        settings.addProvider(other)
        #expect(settings.aiProvider.id == other.id)
        #expect(!settings.wikiAutomaticAllowed)
        #expect(!settings.wikiEnabled)
    }

    @Test func revokingAutomaticTurnsItsFeaturesOffAndFallsBackToOnDeviceTranscription() {
        let settings = cloudSettings()
        settings.wikiEnabled = true
        settings.correctionEnabled = true
        settings.aiTitleCloudEnabled = true
        settings.recordCloudTranscriptionConsent(for: .openAI)
        settings.transcriptionProviderID = AIProvider.openAI.id
        settings.transcriptionEngine = .whisperAPI

        settings.revokeAutomaticCloudConsent(settings.cloudConsentDestination(for: .openAI))

        #expect(!settings.wikiEnabled)
        #expect(!settings.correctionEnabled)
        #expect(!settings.aiTitleCloudEnabled)
        #expect(!settings.hasCloudTranscriptionConsent(for: .openAI))
        #expect(settings.transcriptionEngine == .appleSpeech)
        #expect(settings.allowsCloud(.openAI, for: .onRequest))
        #expect(!settings.allowsCloud(.openAI, for: .automatic))
    }

    @Test func removingAllPermissionsMovesTheSummaryProviderOnDevice() {
        let settings = cloudSettings()
        settings.readAloud.providerID = AIProvider.openAI.id
        settings.revokeAllCloudConsent(settings.cloudConsentDestination(for: .openAI))
        #expect(settings.readAloud.providerID == AIProvider.appleOnDevice.id)
        #expect(settings.aiProviderID == AIProvider.appleOnDevice.id)
        #expect(!settings.allowsCloud(.openAI, for: .onRequest))
        #expect(settings.cloudConsents.destinations.isEmpty)
    }

    @Test func aFallbackNeverReselectsAWithdrawnProvider() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults,
                                   credentials: CredentialStore(keychain: ConsentTestKeychain()))
        settings.credentials.saveKey("sk-test", for: .openAI)
        settings.aiProviderID = AIProvider.openAI.id
        settings.revokeAllCloudConsent(settings.cloudConsentDestination(for: .openAI))
        settings.ensureProviderSelectionsAreUsable()
        #expect(settings.aiProviderID != AIProvider.openAI.id)
    }
}

private final class ConsentTestKeychain: KeychainAccessing, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func get(_ account: String) -> KeychainReadOutcome {
        storage[account].map { .found($0) } ?? .absent
    }

    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteOutcome {
        storage[account] = value
        return .success
    }

    @discardableResult
    func delete(_ account: String) -> KeychainWriteOutcome {
        storage[account] = nil
        return .success
    }
}

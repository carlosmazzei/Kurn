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
        // Audio consent never becomes a text grant.
        #expect(!settings.cloudConsents.allows(destination, for: .automatic))
        #expect(settings.cloudConsentDestinationsForDisplay == [destination])
    }

    @Test func migrationRunsOnce() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = AppSettings(defaults: defaults)
        let stored = try #require(defaults.data(forKey: AppSettings.cloudConsentsKey))
        defaults.set(true, forKey: AppSettings.Keys.wikiEnabled)
        _ = AppSettings(defaults: defaults)
        #expect(defaults.data(forKey: AppSettings.cloudConsentsKey) == stored)
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
    }

    @Test func aTextGrantNeverAuthorizesAnAudioUpload() {
        let settings = cloudSettings()
        settings.aiTitleCloudEnabled = true
        #expect(settings.allowsCloud(.openAI, for: .automatic))
        #expect(!settings.hasCloudTranscriptionConsent(for: .openAI))
    }

    @Test func anAudioConsentNeverAuthorizesTextFeatures() {
        let settings = cloudSettings()
        settings.recordCloudTranscriptionConsent(for: .openAI)
        #expect(settings.hasCloudTranscriptionConsent(for: .openAI))
        #expect(!settings.allowsCloud(.openAI, for: .automatic))
    }

    @Test func switchingSummaryProvidersWithAFeatureOnGrantsTheNewOne() {
        let settings = cloudSettings()
        settings.wikiEnabled = true
        let other = AIProvider(id: "other-test", displayName: "Other", kind: .openAICompatible,
                               baseURLString: "https://other.example.com/v1")
        settings.addProvider(other)
        #expect(settings.aiProvider.id == other.id)
        // The toggle means "send to my summary provider"; the grant is recorded and revocable.
        #expect(settings.wikiEnabled)
        #expect(settings.allowsCloud(other, for: .automatic))
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

    @Test func revokingAudioUploadAloneKeepsAutomaticTextGrantsAndFallsBackToOnDeviceTranscription() {
        let settings = cloudSettings()
        settings.wikiEnabled = true
        settings.recordCloudTranscriptionConsent(for: .openAI)
        settings.transcriptionProviderID = AIProvider.openAI.id
        settings.transcriptionEngine = .whisperAPI
        let destination = settings.cloudConsentDestination(for: .openAI)

        settings.revokeCloudTranscriptionConsent(destination)

        #expect(!settings.hasCloudTranscriptionConsent(for: .openAI))
        #expect(settings.transcriptionEngine == .appleSpeech)
        #expect(settings.wikiEnabled)
        #expect(settings.allowsCloud(.openAI, for: .automatic))
    }

    @Test func revokingAutomaticAlonePreservesOnRequestFromKnowledgeAndKeepsAudioUploadWhenExcluded() {
        let settings = MeetingFixtures.isolatedSettings()
        let destination = settings.cloudConsentDestination(for: .anthropic)
        // Knowledge records only `.automatic`, which also satisfies `.onRequest`.
        settings.grantCloudConsent(.anthropic, for: .automatic)
        settings.recordCloudTranscriptionConsent(for: .anthropic)

        settings.revokeAutomaticCloudConsent(destination, includeAudio: false)

        #expect(!settings.allowsCloud(.anthropic, for: .automatic))
        #expect(settings.allowsCloud(.anthropic, for: .onRequest))
        #expect(settings.hasCloudTranscriptionConsent(for: .anthropic))
    }

    @Test func revokingAfterDisablingSoleAudioPermissionStillClearsReadAloudProvider() {
        let settings = MeetingFixtures.isolatedSettings()
        let destination = settings.cloudConsentDestination(for: .elevenLabs)
        settings.recordCloudTranscriptionConsent(for: .elevenLabs)
        settings.readAloud.providerID = AIProvider.elevenLabs.id

        settings.revokeCloudTranscriptionConsent(destination)
        #expect(!settings.hasCloudTranscriptionConsent(for: .elevenLabs))
        #expect(settings.editableCloudConsentDestinations.contains(destination))

        settings.revokeAllCloudConsent(destination)
        #expect(settings.readAloud.providerID == AIProvider.appleOnDevice.id)
    }

    @Test func editableCloudConsentDestinationsIncludesConfiguredProvidersEvenAfterRevokeAll() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults,
                                   credentials: CredentialStore(keychain: ConsentTestKeychain()))
        settings.credentials.saveKey("sk-openai", for: .openAI)
        let destination = settings.cloudConsentDestination(for: .openAI)
        settings.revokeAllCloudConsent(destination)

        #expect(settings.cloudConsentDestinationsForDisplay.isEmpty)
        #expect(settings.editableCloudConsentDestinations.contains(destination))
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

    @Test func editingTheSummaryEndpointRecordsTheNewDestination() {
        let settings = MeetingFixtures.isolatedSettings()
        let custom = AIProvider(id: "custom-edit", displayName: "Custom", kind: .openAICompatible,
                                baseURLString: "https://one.example.com/v1")
        settings.addProvider(custom)
        settings.aiTitleCloudEnabled = true
        var moved = custom
        moved.baseURLString = "https://two.example.com/v1"
        settings.updateProvider(moved)
        #expect(settings.allowsCloud(moved, for: .automatic))
        #expect(settings.cloudConsentDestinationsForDisplay.contains(settings.cloudConsentDestination(for: moved)))
    }

    @Test func aFallbackRecordsNoAutomaticGrant() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults,
                                   credentials: CredentialStore(keychain: ConsentTestKeychain()))
        settings.credentials.saveKey("sk-openai", for: .openAI)
        settings.credentials.saveKey("sk-anthropic", for: .anthropic)
        settings.aiProviderID = AIProvider.anthropic.id
        settings.wikiEnabled = true

        settings.credentials.saveKey("", for: .anthropic)

        #expect(settings.aiProviderID != AIProvider.anthropic.id)
        #expect(!settings.allowsCloud(.openAI, for: .automatic))
        if settings.aiProvider.kind != .appleOnDevice { #expect(!settings.wikiEnabled) }
    }

    @Test func aFallbackPrefersAProviderThatKeepsAutomationRunning() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults,
                                   credentials: CredentialStore(keychain: ConsentTestKeychain()))
        settings.credentials.saveKey("sk-openai", for: .openAI)
        settings.aiProviderID = AIProvider.openAI.id
        settings.wikiEnabled = true
        settings.addProvider(AIProvider(id: "keyless-test", displayName: "Keyless", kind: .openAICompatible,
                                        baseURLString: "https://keyless.example.com/v1"))

        settings.ensureProviderSelectionsAreUsable()

        #expect(settings.aiProviderID != "keyless-test")
        #expect(settings.wikiEnabled)
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

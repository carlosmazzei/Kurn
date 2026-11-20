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

    @Test func enablingTheWikiGrantsAutomaticSendingToTheSummaryProvider() {
        let settings = MeetingFixtures.isolatedSettings()
        let provider = settings.aiProvider
        settings.wikiEnabled = true
        #expect(settings.allowsCloud(provider, for: .automatic) || provider.kind == .appleOnDevice)
    }

    @Test func revokingAutomaticTurnsItsFeaturesOff() {
        let settings = MeetingFixtures.isolatedSettings()
        let provider = settings.aiProvider
        settings.wikiEnabled = true
        settings.correctionEnabled = true
        settings.aiTitleCloudEnabled = true
        settings.recordCloudTranscriptionConsent(for: provider)
        settings.grantCloudConsent(provider, for: .onRequest)

        settings.revokeAutomaticCloudConsent(settings.cloudConsentDestination(for: provider))

        #expect(!settings.wikiEnabled)
        #expect(!settings.correctionEnabled)
        #expect(!settings.aiTitleCloudEnabled)
        if provider.kind != .appleOnDevice {
            #expect(!settings.hasCloudTranscriptionConsent(for: provider))
            #expect(settings.allowsCloud(provider, for: .onRequest))
        }
    }
}

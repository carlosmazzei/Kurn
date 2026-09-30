//
//  CredentialStoreTests.swift
//  KurnTests
//
//  `CredentialStore` replaced a `keyRevision` counter threaded by hand through
//  the Settings screens, and moved the "a selection must point at a provider
//  with a key" invariant out of a view. These pin both halves against an
//  in-memory Keychain: writes are observable and cached answers never outlive
//  them, and every write re-applies the invariant wherever it happens.
//

import Foundation
import Testing
@testable import Kurn

@MainActor
struct CredentialStoreTests {

    // MARK: - Store

    @Test func saveKeyBumpsRevisionAndIsVisibleImmediately() {
        let keychain = InMemoryKeychain()
        let store = CredentialStore(keychain: keychain)
        #expect(!store.hasKey(for: .openAI))
        let before = store.revision

        let outcome = store.saveKey("  sk-test  ", for: .openAI)

        #expect(outcome == .success)
        #expect(store.revision != before)
        #expect(store.hasKey(for: .openAI))
        #expect(keychain.storage[AIProvider.openAI.keychainAccount] == "sk-test")
    }

    @Test func emptyKeyRemovesTheStoredOne() {
        let keychain = InMemoryKeychain()
        let store = CredentialStore(keychain: keychain)
        store.saveKey("sk-test", for: .openAI)

        store.saveKey("   ", for: .openAI)

        #expect(!store.hasKey(for: .openAI))
        #expect(keychain.storage[AIProvider.openAI.keychainAccount] == nil)
    }

    @Test func cachedAnswerIsDroppedOnInvalidate() {
        let keychain = InMemoryKeychain()
        let store = CredentialStore(keychain: keychain)
        #expect(!store.hasKey(for: .openAI))

        // A write the store did not make: the cached "absent" still stands…
        keychain.storage[AIProvider.openAI.keychainAccount] = "sk-outside"
        #expect(!store.hasKey(for: .openAI))

        // …until something invalidates it.
        store.invalidate()
        #expect(store.hasKey(for: .openAI))
    }

    @Test func failedReadIsNotRememberedAsNoKey() {
        let keychain = InMemoryKeychain()
        keychain.storage[AIProvider.openAI.keychainAccount] = "sk-test"
        keychain.forcedFailure = .locked
        let store = CredentialStore(keychain: keychain)

        #expect(!store.hasKey(for: .openAI))

        keychain.forcedFailure = nil
        #expect(store.hasKey(for: .openAI))
    }

    // MARK: - Selection invariant

    @Test func removingTheSelectedSummaryProvidersKeyRepointsTheSelection() throws {
        let (settings, _) = try makeSettings()
        settings.credentials.saveKey("sk-openai", for: .openAI)
        settings.credentials.saveKey("sk-anthropic", for: .anthropic)
        settings.aiProviderID = AIProvider.anthropic.id

        settings.credentials.saveKey("", for: .anthropic)

        #expect(settings.aiProviderID != AIProvider.anthropic.id)
        #expect(settings.configuredSummaryProviders.contains { $0.id == settings.aiProviderID })
    }

    @Test func removingTheLastTranscriptionKeyFallsBackToOnDeviceTranscription() throws {
        let (settings, _) = try makeSettings()
        settings.credentials.saveKey("sk-openai", for: .openAI)
        settings.transcriptionEngine = .whisperAPI
        settings.transcriptionProviderID = AIProvider.openAI.id

        settings.credentials.saveKey("", for: .openAI)

        #expect(settings.transcriptionEngine == .appleSpeech)
    }

    @Test func removingAProviderRemovesItsKey() throws {
        let (settings, keychain) = try makeSettings()
        let custom = AIProvider(
            id: "custom-\(UUID().uuidString)",
            displayName: "Custom",
            kind: .openAICompatible,
            baseURLString: "https://example.com/v1"
        )
        settings.addProvider(custom)
        settings.credentials.saveKey("sk-custom", for: custom)

        settings.removeProvider(custom)

        #expect(keychain.storage[custom.keychainAccount] == nil)
        #expect(!settings.credentials.hasKey(for: custom))
    }

    // MARK: - Helpers

    private func makeSettings() throws -> (AppSettings, InMemoryKeychain) {
        let defaults = try #require(UserDefaults(suiteName: "CredentialStoreTests-\(UUID().uuidString)"))
        let keychain = InMemoryKeychain()
        let settings = AppSettings(
            cloudStore: InMemoryCloudKeyValueStore(),
            defaults: defaults,
            credentials: CredentialStore(keychain: keychain)
        )
        return (settings, keychain)
    }
}

/// A `KeychainAccessing` conformer with no Security-framework dependency.
private final class InMemoryKeychain: KeychainAccessing, @unchecked Sendable {
    var storage: [String: String] = [:]
    var forcedFailure: KeychainFailureReason?

    func get(_ account: String) -> KeychainReadOutcome {
        if let forcedFailure { return .failed(forcedFailure) }
        guard let value = storage[account] else { return .absent }
        return .found(value)
    }

    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteOutcome {
        if let forcedFailure { return .failed(forcedFailure) }
        storage[account] = value
        return .success
    }

    @discardableResult
    func delete(_ account: String) -> KeychainWriteOutcome {
        if let forcedFailure { return .failed(forcedFailure) }
        storage[account] = nil
        return .success
    }
}

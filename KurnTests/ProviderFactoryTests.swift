//
//  ProviderFactoryTests.swift
//  KurnTests
//
//  Exercises the real Keychain (via KeychainManager.shared) since that is the
//  only place the "do we have a key?" decision can be observed end to end.
//  Each test snapshots and restores whatever was already stored so it doesn't
//  leak state into other tests or the app itself.
//

import Testing
@testable import Kurn

struct ProviderFactoryTests {

    private func withClearedKey<R>(_ key: KeychainKey, _ body: () throws -> R) rethrows -> R {
        let original = KeychainManager.shared.get(key)
        KeychainManager.shared.delete(key)
        defer {
            if let original { KeychainManager.shared.set(original, for: key) } else { KeychainManager.shared.delete(key) }
        }
        return try body()
    }

    private func withKey<R>(_ key: KeychainKey, value: String, _ body: () throws -> R) rethrows -> R {
        let original = KeychainManager.shared.get(key)
        KeychainManager.shared.set(value, for: key)
        defer {
            if let original { KeychainManager.shared.set(original, for: key) } else { KeychainManager.shared.delete(key) }
        }
        return try body()
    }

    @Test func summaryProviderThrowsNoAPIKeyWhenKeychainIsEmpty() {
        withClearedKey(.openAI) {
            #expect(throws: AppError.self) {
                _ = try ProviderFactory.summaryProvider(for: .openAI, model: "gpt-4o")
            }
        }
    }

    @Test func summaryProviderBuildsOpenAIProviderWhenKeyPresent() throws {
        try withKey(.openAI, value: "test-key") {
            let provider = try ProviderFactory.summaryProvider(for: .openAI, model: "gpt-4o")
            #expect(provider.provider == .openAI)
        }
    }

    @Test func summaryProviderBuildsAnthropicProviderWhenKeyPresent() throws {
        try withKey(.anthropic, value: "test-key") {
            let provider = try ProviderFactory.summaryProvider(for: .anthropic, model: "claude-3-5-sonnet-latest")
            #expect(provider.provider == .anthropic)
        }
    }

    @Test func whisperProviderThrowsNoAPIKeyWhenOpenAIKeyIsEmpty() {
        withClearedKey(.openAI) {
            #expect(throws: AppError.self) {
                _ = try ProviderFactory.whisperProvider()
            }
        }
    }
}

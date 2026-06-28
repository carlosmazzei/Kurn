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

// Serialized because these tests mutate the real, process-wide Keychain
// (`KeychainManager.shared`) — several share the `.openAI` key, so running them
// in parallel races on set/delete (one test clears the key while another expects
// it set). Matches the same precaution in `ProviderHTTPTests`.
@Suite(.serialized)
struct ProviderFactoryTests {

    @discardableResult
    private func withClearedKey<R>(_ key: KeychainKey, _ body: () throws -> R) rethrows -> R {
        let original = KeychainManager.shared.get(key)
        KeychainManager.shared.delete(key)
        defer {
            if let original { KeychainManager.shared.set(original, for: key) } else { KeychainManager.shared.delete(key) }
        }
        return try body()
    }

    @discardableResult
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

    @Test func summaryProviderBuildsGoogleProviderWhenKeyPresent() throws {
        try withKey(.google, value: "test-key") {
            let provider = try ProviderFactory.summaryProvider(for: .google, model: "gemini-1.5-pro")
            #expect(provider.provider == .google)
        }
    }

    @Test func summaryProviderResolvesDefaultModelWhenModelEmpty() throws {
        // An empty model resolves to the provider's defaultModel, so building
        // still succeeds (the built-in providers all have a non-empty default).
        try withKey(.openAI, value: "test-key") {
            let provider = try ProviderFactory.summaryProvider(for: .openAI, model: "")
            #expect(provider.provider == .openAI)
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

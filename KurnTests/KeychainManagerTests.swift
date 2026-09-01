//
//  KeychainManagerTests.swift
//  KurnTests
//
//  H7 PR 14: proves the `KeychainAccessing` seam actually works as a
//  mockable abstraction (a fake conforming to it, exercised the same way a
//  view model would use the real one), pins the pure `OSStatus` →
//  `KeychainFailureReason` classification, and round-trips the concrete
//  `KeychainManager` against the real Keychain the same way
//  `ProviderFactoryTests` already does for provider resolution. Uses its own
//  dedicated account string (never `.openAI`/`.anthropic`/`.google`/`.groq`),
//  so it doesn't need to serialize against `ProviderFactoryTests` — but is
//  itself `.serialized` for the same reason that suite already documents:
//  the three `realManagerXXX` tests below share that one account, and Swift
//  Testing parallelizes sibling tests by default, so without it they raced
//  on set/get/delete of the same Keychain item and failed intermittently in
//  CI.
//

import Security
import Testing
@testable import Kurn

/// A `KeychainAccessing` conformer with no Security-framework dependency,
/// so a caller's handling of every outcome — including the ones the real
/// Keychain only produces on a locked/denied device — can be exercised
/// deterministically.
private final class FakeKeychainAccessing: KeychainAccessing, @unchecked Sendable {
    private var storage: [String: String] = [:]
    var forcedFailure: KeychainFailureReason?

    func get(_ account: String) -> KeychainReadOutcome {
        if let forcedFailure { return .failed(forcedFailure) }
        guard let value = storage[account] else { return .absent }
        return .found(value)
    }

    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteOutcome {
        if let forcedFailure { return .failed(forcedFailure) }
        guard !value.isEmpty else { return delete(account) }
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

// Serialized because the `realManagerXXX` tests below share one Keychain
// account and mutate the real, process-wide Keychain — the same precaution
// `ProviderFactoryTests` takes for the same reason.
@Suite(.serialized)
struct KeychainManagerTests {

    // MARK: - The seam itself, via a fake

    @Test func fakeRoundTripsThroughTheSharedConvenienceExtension() {
        let fake = FakeKeychainAccessing()
        #expect(fake.value(for: "acct") == nil)
        #expect(!fake.hasValue(for: "acct"))

        fake.set("secret", for: "acct")
        #expect(fake.value(for: "acct") == "secret")
        #expect(fake.hasValue(for: "acct"))

        fake.delete("acct")
        #expect(fake.value(for: "acct") == nil)
    }

    @Test func settingAnEmptyValueDeletes() {
        let fake = FakeKeychainAccessing()
        fake.set("secret", for: "acct")
        fake.set("", for: "acct")
        #expect(fake.get("acct") == .absent)
    }

    @Test func aForcedFailureIsNeverCollapsedToAbsentByTheConvenienceExtension() {
        let fake = FakeKeychainAccessing()
        fake.set("secret", for: "acct")
        fake.forcedFailure = .locked

        // The raw seam still reports the real classification...
        #expect(fake.get("acct") == .failed(.locked))
        // ...but the convenience extension used by most call sites collapses
        // it to the same shape as "absent" by design (`value(for:)`'s own
        // documented caveat) — this test pins that collapsing is deliberate,
        // not a bug, and only ever a problem for a caller that needs to tell
        // the two apart, which is exactly why `get(_:)` exists separately.
        #expect(fake.value(for: "acct") == nil)
    }

    @Test func writeOutcomesCarryTheirFailureReason() {
        let fake = FakeKeychainAccessing()
        fake.forcedFailure = .denied
        #expect(fake.set("value", for: "acct") == .failed(.denied))
        #expect(fake.delete("acct") == .failed(.denied))
    }

    // MARK: - `KeychainManager.classify` — pure `OSStatus` mapping

    @Test func classifyMapsInteractionNotAllowedToLocked() {
        #expect(KeychainManager.classify(errSecInteractionNotAllowed) == .locked)
    }

    @Test func classifyMapsAuthFailedAndNotAvailableToDenied() {
        #expect(KeychainManager.classify(errSecAuthFailed) == .denied)
        #expect(KeychainManager.classify(errSecNotAvailable) == .denied)
    }

    @Test func classifyMapsAnyOtherStatusToTransient() {
        #expect(KeychainManager.classify(errSecDuplicateItem) == .transient)
        #expect(KeychainManager.classify(-1) == .transient)
    }

    // MARK: - The concrete `KeychainManager`, round-tripped against the real Keychain

    /// A dedicated account, never used by `ProviderFactoryTests` or any
    /// provider's real `keychainAccount`, so this suite doesn't need
    /// `.serialized` against them.
    private let testAccount = "ai.kurn.tests.keychainManagerTests"

    @Test func realManagerReportsAbsentThenFoundThenAbsentAgain() {
        KeychainManager.shared.delete(testAccount)
        defer { KeychainManager.shared.delete(testAccount) }

        #expect(KeychainManager.shared.get(testAccount) == .absent)

        #expect(KeychainManager.shared.set("a-value", for: testAccount) == .success)
        #expect(KeychainManager.shared.get(testAccount) == .found("a-value"))

        // Overwriting an existing item exercises the update path, not just add.
        #expect(KeychainManager.shared.set("a-new-value", for: testAccount) == .success)
        #expect(KeychainManager.shared.get(testAccount) == .found("a-new-value"))

        #expect(KeychainManager.shared.delete(testAccount) == .success)
        #expect(KeychainManager.shared.get(testAccount) == .absent)
    }

    @Test func realManagerSettingEmptyValueDeletes() {
        KeychainManager.shared.set("a-value", for: testAccount)
        defer { KeychainManager.shared.delete(testAccount) }

        #expect(KeychainManager.shared.set("", for: testAccount) == .success)
        #expect(KeychainManager.shared.get(testAccount) == .absent)
    }

    @Test func realManagerDeletingAnAbsentAccountIsStillSuccess() {
        KeychainManager.shared.delete(testAccount)
        #expect(KeychainManager.shared.delete(testAccount) == .success)
    }
}

//
//  CredentialStore.swift
//  Kurn
//
//  The UI's one door to the provider API keys in the Keychain, owned by
//  `AppSettings` (`settings.credentials`) so every screen that reaches
//  settings reaches it too — including Settings rendered in the security cover
//  window.
//
//  The Keychain is not observable. The Settings screens used to compensate
//  with a `keyRevision` counter threaded by hand through every screen and
//  bumped at each write, and read `SecItemCopyMatching` on every body
//  evaluation; a screen the counter wasn't threaded to (the transcription
//  settings opened from Recording or from a meeting) simply never refreshed.
//  Every write now goes through here and bumps an observable `revision`, so
//  any view that asks `hasKey(for:)`/`isUsable(_:)` re-renders on its own,
//  and definitive answers are cached until the next write.
//
//  Non-UI code (`ProviderFactory`, services off the main actor) keeps reading
//  `KeychainManager` and `AIProvider.isUsable` directly: it needs the value at
//  call time, not a re-render.
//

import Foundation
import Observation

@MainActor
@Observable
final class CredentialStore {
    /// Bumped on every write; reading it registers a view for re-render.
    private(set) var revision = 0

    /// Called after every write, so `AppSettings` can repoint a selection
    /// whose provider just lost its key.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let keychain: any KeychainAccessing
    /// Presence per Keychain account. Only definitive answers are cached: a
    /// failed read (device locked, transient error) is asked again next time
    /// rather than remembered as "no key".
    @ObservationIgnored private var presence: [String: Bool] = [:]

    init(keychain: any KeychainAccessing = KeychainManager.shared) {
        self.keychain = keychain
    }

    /// Whether a non-empty key is stored for `provider`.
    func hasKey(for provider: AIProvider) -> Bool {
        _ = revision
        let account = provider.keychainAccount
        if let cached = presence[account] { return cached }
        switch keychain.get(account) {
        case .found(let value):
            presence[account] = !value.isEmpty
            return !value.isEmpty
        case .absent:
            presence[account] = false
            return false
        case .failed:
            return false
        }
    }

    /// The UI counterpart of `AIProvider.isUsable`: a key for a cloud vendor,
    /// or a runnable on-device model for the provider that has no key.
    func isUsable(_ provider: AIProvider) -> Bool {
        provider.kind == .appleOnDevice
            ? OnDeviceModelAvailability.unavailableReason == nil
            : hasKey(for: provider)
    }

    /// The UI counterpart of `AIProvider.isUsableForSpeech`: the system voice,
    /// or a speaking cloud vendor with a key.
    func isUsableForSpeech(_ provider: AIProvider) -> Bool {
        guard let api = provider.speechSynthesisAPI else { return false }
        return api == .system || hasKey(for: provider)
    }

    /// The stored key itself, for the editor that shows it. Not cached.
    func readKey(for provider: AIProvider) -> KeychainReadOutcome {
        _ = revision
        return keychain.get(provider.keychainAccount)
    }

    /// Stores `key` for `provider`, or removes it when `key` is empty after
    /// trimming. Every outcome, failure included, invalidates the cache.
    @discardableResult
    func saveKey(_ key: String, for provider: AIProvider) -> KeychainWriteOutcome {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = trimmed.isEmpty
            ? keychain.delete(provider.keychainAccount)
            : keychain.set(trimmed, for: provider.keychainAccount)
        invalidate()
        return outcome
    }

    /// Forgets every cached answer and notifies observers — for changes the
    /// store can't see itself, such as a provider's kind being edited.
    func invalidate() {
        presence.removeAll()
        revision &+= 1
        onChange?()
    }
}

//
//  KeychainManager.swift
//  Kurn
//
//  Thin wrapper over the Security framework for storing API keys. Keys live in
//  the keychain (never UserDefaults) with `AfterFirstUnlockThisDeviceOnly` access
//  so they are not included in encrypted backups, never leave the device, and
//  remain readable by background tasks after the first unlock of the day.
//
//  H7 PR 14: every operation used to collapse any Security-framework failure
//  into the same value as "not configured" — `get` returned `nil` for a
//  locked device exactly as it did for a key that was never stored, and
//  `set`/`delete` discarded their `OSStatus` outright. That made a transient
//  or locked-device failure indistinguishable from "the user never added a
//  key," which is what let the accessibility migration below mark itself
//  complete after a failed read. `KeychainReadOutcome`/`KeychainWriteOutcome`
//  restore that distinction without ever exposing the raw `OSStatus` itself
//  outside this file — only the closed `KeychainFailureReason` bucket does.
//

import Foundation
import Security

/// Stable keychain account identifiers.
enum KeychainKey: String, CaseIterable {
    case openAI = "openai_api_key"
    case anthropic = "anthropic_api_key"
    case google = "google_api_key"
    case groq = "groq_api_key"
}

/// Why a Keychain operation didn't simply succeed — retryable, and never to
/// be treated the same as "no value stored" (H7 PR 14).
enum KeychainFailureReason: String, Equatable, Sendable {
    /// Protected data isn't available right now (`errSecInteractionNotAllowed`),
    /// typically a locked device or a background launch before first unlock.
    case locked
    /// Explicitly denied (`errSecAuthFailed`/`errSecNotAvailable`).
    case denied
    /// Any other Security-framework failure — worth retrying.
    case transient
}

enum KeychainReadOutcome: Equatable, Sendable {
    case found(String)
    case absent
    case failed(KeychainFailureReason)
}

enum KeychainWriteOutcome: Equatable, Sendable {
    case success
    case failed(KeychainFailureReason)
}

/// The generic, string-account seam `KeychainManager` conforms to — the same
/// shape `CloudKeyValueStore` gives `NSUbiquitousKeyValueStore`, so a fake can
/// stand in for tests without touching the real, process-wide Keychain.
protocol KeychainAccessing: AnyObject, Sendable {
    func get(_ account: String) -> KeychainReadOutcome
    @discardableResult func set(_ value: String, for account: String) -> KeychainWriteOutcome
    @discardableResult func delete(_ account: String) -> KeychainWriteOutcome
}

extension KeychainAccessing {
    /// Convenience for call sites that only need "is there a value", and are
    /// fine treating any failure the same as absent — every read except the
    /// explicit-Save/edit UI path, which needs to tell them apart (H7 PR 14).
    func value(for account: String) -> String? {
        if case .found(let value) = get(account) { return value }
        return nil
    }

    /// True when a non-empty value is present. Same failure-collapsing caveat
    /// as `value(for:)`.
    func hasValue(for account: String) -> Bool {
        guard let value = value(for: account) else { return false }
        return !value.isEmpty
    }
}

/// Serializes all keychain access. The Security APIs are thread-safe, but a
/// singleton keeps a single service-name namespace and a single call site.
final class KeychainManager: KeychainAccessing, @unchecked Sendable {
    static let shared = KeychainManager()

    private let service = "ai.kurn.apikeys"

    private init() {}

    // MARK: - `KeychainKey` convenience overloads

    func get(_ key: KeychainKey) -> KeychainReadOutcome { get(key.rawValue) }
    @discardableResult func set(_ value: String, for key: KeychainKey) -> KeychainWriteOutcome { set(value, for: key.rawValue) }
    @discardableResult func delete(_ key: KeychainKey) -> KeychainWriteOutcome { delete(key.rawValue) }
    func value(for key: KeychainKey) -> String? { value(for: key.rawValue) }
    func hasValue(for key: KeychainKey) -> Bool { hasValue(for: key.rawValue) }

    // MARK: - `KeychainAccessing`

    /// Read a dynamic provider value.
    func get(_ account: String) -> KeychainReadOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                // Present but undecodable is not "absent" — it's corruption
                // worth surfacing, not silently treated as no key stored.
                return .failed(.transient)
            }
            return .found(value)
        case errSecItemNotFound:
            return .absent
        default:
            return .failed(Self.classify(status))
        }
    }

    /// Store (or overwrite) a value for a dynamic provider account. An empty
    /// value deletes instead — callers deciding between set/delete based on
    /// their own "did the user clear the field" logic get the same outcome
    /// type back either way.
    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteOutcome {
        guard !value.isEmpty else { return delete(account) }
        guard let data = value.data(using: .utf8) else { return .failed(.transient) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return .success }
        guard updateStatus == errSecItemNotFound else { return .failed(Self.classify(updateStatus)) }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess ? .success : .failed(Self.classify(addStatus))
    }

    @discardableResult
    func delete(_ account: String) -> KeychainWriteOutcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Deleting something already absent is the caller's desired end
        // state, not a failure.
        return (status == errSecSuccess || status == errSecItemNotFound) ? .success : .failed(Self.classify(status))
    }

    /// Maps a Security-framework status to the closed, exportable-safe
    /// classification the rest of the app is allowed to see — the raw
    /// `OSStatus` itself never leaves this type.
    static func classify(_ status: OSStatus) -> KeychainFailureReason {
        switch status {
        case errSecInteractionNotAllowed:
            return .locked
        case errSecAuthFailed, errSecNotAvailable:
            return .denied
        default:
            return .transient
        }
    }

    // MARK: - Accessibility migration

    /// Re-save all stored keys under this service with `AfterFirstUnlockThisDeviceOnly`
    /// accessibility so background transcription tasks can read them after the
    /// first device unlock, without waiting for the screen to be unlocked again.
    /// Must be called from the foreground (device unlocked) — typically once at
    /// app launch. Safe to call repeatedly; each call is a no-op once the
    /// migration flag is set.
    ///
    /// The flag is only ever set after a *confirmed* outcome — either there is
    /// nothing to migrate (`errSecItemNotFound`), or every item that needed
    /// re-saving was re-saved successfully. A locked device, a denied access,
    /// or any other transient failure — whether on the initial fetch or on one
    /// item's re-save — leaves the flag unset so the next launch retries,
    /// instead of the old behavior of marking migration "done" after a failed
    /// fetch that looked identical to "nothing stored" (H7 PR 14).
    func migrateToBackgroundAccessible() {
        let migrationKey = "ai.kurn.keychain.migratedAfterFirstUnlock"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecItemNotFound:
            // Nothing stored yet — migration is trivially complete.
            UserDefaults.standard.set(true, forKey: migrationKey)
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                AppLog.persistence.atError.error("keychain: migration copy returned an unexpected shape; will retry next launch")
                return
            }
            var migratedCount = 0
            var allSucceeded = true
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8),
                      !value.isEmpty else { continue }
                if set(value, for: account) == .success {
                    migratedCount += 1
                } else {
                    allSucceeded = false
                }
            }
            guard allSucceeded else {
                AppLog.persistence.atError.error("keychain: migration failed for one or more items; will retry next launch")
                return
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
            AppLog.persistence.atNotice.notice("keychain: migrated \(migratedCount, privacy: .public) item(s) to AfterFirstUnlock accessibility")
        default:
            AppLog.persistence.atError.error("keychain: migration fetch failed (\(Self.classify(status).rawValue, privacy: .public)); will retry next launch")
        }
    }
}

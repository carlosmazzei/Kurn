//
//  KeychainManager.swift
//  MeetSync
//
//  Thin wrapper over the Security framework for storing API keys. Keys live in
//  the keychain (never UserDefaults) with `WhenUnlockedThisDeviceOnly` access so
//  they are not included in encrypted backups and never leave the device.
//

import Foundation
import Security

/// Stable keychain account identifiers.
enum KeychainKey: String, CaseIterable {
    case openAI = "openai_api_key"
    case anthropic = "anthropic_api_key"
}

/// Serializes all keychain access. The Security APIs are thread-safe, but a
/// singleton keeps a single service-name namespace and a single call site.
final class KeychainManager: @unchecked Sendable {
    static let shared = KeychainManager()

    private let service = "com.meetsync.apikeys"

    private init() {}

    /// Store (or overwrite) a value. Passing an empty/nil string deletes it.
    func set(_ value: String?, for key: KeychainKey) {
        guard let value, !value.isEmpty else {
            delete(key)
            return
        }
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Read a value, or `nil` if absent.
    func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Convenience: true when a non-empty value is present.
    func hasValue(for key: KeychainKey) -> Bool {
        guard let value = get(key) else { return false }
        return !value.isEmpty
    }

    func delete(_ key: KeychainKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

//
//  CloudSettingsSync.swift
//  Kurn
//
//  Syncs small, non-secret app settings (custom summary templates) via iCloud
//  key-value storage — Apple's own recommendation for preferences that should
//  follow a user across devices. Deliberately not CloudKit or SwiftData+CloudKit:
//  those would pull the app's SwiftData container (meeting/transcript/summary
//  content) toward iCloud, which conflicts with the local-first design. Only
//  `AppSettings` decides what gets written here; this type is just the transport.
//

import Foundation

/// Seam over `NSUbiquitousKeyValueStore` so sync logic is testable without a
/// signed-in iCloud account (CI runs with none).
protocol CloudKeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
    /// Fires with the changed keys whenever another device (or process) wrote
    /// to the store. Always delivered on the main queue. Not `@Sendable`: the
    /// only conforming types are `@unchecked Sendable` themselves, and the
    /// closure is set once, from the main actor, by `AppSettings.init`.
    var didChangeExternally: (([String]) -> Void)? { get set }
}

/// Thin wrapper over `NSUbiquitousKeyValueStore.default`, in the same spirit
/// as `KeychainManager`: no business logic, just get/set/observe.
final class CloudSettingsSync: CloudKeyValueStore, @unchecked Sendable {
    static let shared = CloudSettingsSync()

    // H8 PR 18: this used to be a plain mutable `var`, with the only
    // protection a comment claiming "set once, from the main actor, by
    // `AppSettings.init`" — true in practice (the sole writer is
    // `AppSettings.init`, the sole reader is this file's own notification
    // callback, and both happen to run on the main queue), but nothing
    // enforced it: the type is `@unchecked Sendable`, so any code on any
    // thread could legally set this property without the compiler noticing.
    // A lock makes the "single, safe" claim executable instead of only
    // documented, matching every other mutable-state `@unchecked Sendable`
    // in this codebase (`RecordingSink`, `NetworkPathObserver`,
    // `ModelFileDownloader.Downloader`, …).
    private let lock = NSLock()
    private var storedDidChangeExternally: (([String]) -> Void)?
    var didChangeExternally: (([String]) -> Void)? {
        get { lock.withLock { storedDidChangeExternally } }
        set { lock.withLock { storedDidChangeExternally = newValue } }
    }

    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            self?.didChangeExternally?(changedKeys)
        }
        store.synchronize()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    /// `nil` removes the key. Every write also asks the daemon to push soon —
    /// `synchronize()` isn't required by Apple's docs, but it's cheap and
    /// avoids waiting on the OS's own flush interval.
    func setData(_ data: Data?, forKey key: String) {
        if let data {
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }
}

//
//  ModelStoreProtection.swift
//  Kurn
//
//  Upgrades the SwiftData store's file protection to match the audio's
//  `.completeUnlessOpen` class (see RecordingProtection). Transcript and
//  summary text is persisted as JSON `Data` inside this store, so without
//  this it would sit under the weaker default protection class iOS applies
//  automatically to app data. Applying the attribute in place (rather than
//  relocating the store to a new URL) means a wrong assumption about the
//  file name is a silent no-op, never a data-loss risk.
//

import Foundation

enum ModelStoreProtection {
    /// Name SwiftData uses for the store when `ModelConfiguration` is given
    /// no explicit `url:`, placed at the root of Application Support.
    static let baseName = "default.store"
    /// WAL-mode SQLite sidecar files that travel alongside the store.
    static let sidecarSuffixes = ["-shm", "-wal"]

    /// Apply the protection attribute to the store and its sidecars. Must run
    /// before `ModelContainer` is created so the (currently closed) files are
    /// already protected when SwiftData reopens them for this session. Safe
    /// no-op if the files don't exist yet (fresh install) or Application
    /// Support can't be resolved.
    static func apply(appSupportOverride: URL? = nil) {
        let fm = FileManager.default
        let appSupport = appSupportOverride ?? (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ))
        guard let appSupport else { return }
        for suffix in [""] + sidecarSuffixes {
            RecordingProtection.apply(to: appSupport.appendingPathComponent(baseName + suffix))
        }
    }
}

//
//  RecordingProtection.swift
//  Kurn
//
//  Applies iOS Data Protection to the on-disk recordings directory so that
//  meeting audio is encrypted at rest with a key derived from the device
//  passcode. Files in a directory with `.completeUnlessOpen` are inaccessible
//  when the device is locked unless they were already open for writing
//  (i.e. a recording started before the screen locked); a finalised `.m4a`
//  cannot be opened until the user unlocks. The bytes are unrecoverable from
//  an unencrypted backup or device extraction without the passcode.
//

import Foundation
import SwiftData

enum RecordingProtection {
    /// Subdirectory under Documents that holds all recording `.m4a` files.
    /// Kept separate from Documents itself so the protection class is set
    /// once on the container and inherited by newly created files.
    static let directoryName = "Recordings"

    /// Protection class applied to the recordings directory. `.completeUnlessOpen`
    /// is chosen over `.complete` so that an in-progress recording survives the
    /// screen locking mid-meeting — the file stays writable while it is open,
    /// and becomes fully encrypted once `AVAudioFile` closes it.
    static let protectionType: FileProtectionType = .completeUnlessOpen

    /// Create the directory if needed and apply the protection attribute.
    /// Returns the directory URL. Idempotent: safe to call on every launch.
    @discardableResult
    static func ensureProtectedDirectory(at parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(directoryName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: protectionType]
            )
        } else {
            try fm.setAttributes(
                [.protectionKey: protectionType],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    /// Apply the protection attribute to a single file. Silently ignored for
    /// missing files so callers can fire-and-forget after writing.
    static func apply(to fileURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            try fm.setAttributes(
                [.protectionKey: protectionType],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLog.recorder.atError.error(
                "protection: failed to set on \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Move every legacy `.m4a` left in the Documents root into the protected
    /// subdirectory, and re-apply the protection class to every file already in
    /// it. Idempotent: a second invocation is a cheap no-op. Called from
    /// `RecordingRecovery.recoverOrphans` at launch.
    static func migrateLegacyRecordings(
        documentsURL: URL,
        recordingsURL: URL
    ) {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) {
            for legacy in items where legacy.pathExtension.lowercased() == "m4a" {
                let destination = recordingsURL.appendingPathComponent(legacy.lastPathComponent)
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: legacy)
                    continue
                }
                do {
                    try fm.moveItem(at: legacy, to: destination)
                    apply(to: destination)
                    AppLog.recorder.atNotice.notice(
                        "protection: migrated \(legacy.lastPathComponent, privacy: .public)"
                    )
                } catch {
                    AppLog.recorder.atError.error(
                        "protection: migrate failed for \(legacy.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        if let existing = try? fm.contentsOfDirectory(
            at: recordingsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in existing where url.pathExtension.lowercased() == "m4a" {
                apply(to: url)
            }
        }
    }
}

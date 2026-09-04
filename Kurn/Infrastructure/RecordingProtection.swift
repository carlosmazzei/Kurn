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

    /// Subdirectory of the recordings directory holding the derived, enhanced
    /// listening copies.
    ///
    /// A nested directory rather than a filename suffix beside the originals, and
    /// that is load-bearing: every existing sweep over the recordings directory
    /// (`RecordingRecovery`'s orphan pass, `AudioFileStore.totalAudioBytes`, the
    /// legacy migration below) uses a *shallow* `contentsOfDirectory`, so a
    /// subdirectory is invisible to all of them by construction instead of each
    /// one needing to learn an exclusion. Getting that wrong is not benign — the
    /// orphan sweep parses the meeting ID from the name prefix, so a suffixed copy
    /// would be adopted as a second `Recording` and show up in the library as a
    /// duplicate.
    static let enhancedDirectoryName = "Enhanced"

    /// Subdirectory of the recordings directory holding files moved aside by
    /// `RecordingTrash` during a delete that has not yet committed (or has
    /// committed but not yet been purged). Same shallow-scan invisibility as
    /// `enhancedDirectoryName` above, for the same reason: every sweep filters
    /// by `.m4a` extension, so a directory entry here is skipped by
    /// construction rather than by each sweep learning a new exclusion.
    static let trashDirectoryName = "Trash"

    /// Subdirectory of the recordings directory holding originals moved aside
    /// by `RecordingQuarantine` instead of being deleted: unmatched orphans,
    /// unreadable containers, and legacy-migration collisions. Same
    /// shallow-scan invisibility as `trashDirectoryName`, for the same reason.
    static let quarantineDirectoryName = "Quarantine"

    /// Subdirectory of the recordings directory holding
    /// `RecordingOperationJournal`'s durable operation records. Same
    /// shallow-scan invisibility as `trashDirectoryName`, for the same reason.
    static let journalDirectoryName = "Journal"

    /// Protection class applied to the recordings directory. `.completeUnlessOpen`
    /// is chosen over `.complete` so that an in-progress recording survives the
    /// screen locking mid-meeting — the file stays writable while it is open,
    /// and becomes fully encrypted once `AVAudioFile` closes it.
    static let protectionType: FileProtectionType = .completeUnlessOpen

    /// Create the directory if needed and apply the protection attribute.
    /// Returns the directory URL. Idempotent: safe to call on every launch.
    @discardableResult
    static func ensureProtectedDirectory(at parent: URL, fileManager: FileManager = .default) throws -> URL {
        try ensureProtectedDirectory(named: directoryName, in: parent, fileManager: fileManager)
    }

    /// Same, for an arbitrary child directory — used for the enhanced-audio
    /// subdirectory, which needs the identical protection class.
    @discardableResult
    static func ensureProtectedDirectory(
        named name: String,
        in parent: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        let fm = fileManager
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

    /// Protection class for short-lived pipeline artifacts — exported upload
    /// chunks and multipart request bodies — that must stay readable while the
    /// device is locked, so a background transcription can keep feeding
    /// uploads after the screen turns off. Weaker than `.completeUnlessOpen`
    /// (the file key stays available after the first unlock of the boot), but
    /// these are transient copies deleted when the run finishes; the original
    /// recordings keep the stronger class.
    static let inFlightProtectionType: FileProtectionType = .completeUntilFirstUserAuthentication

    /// Apply the protection attribute to a single file. Silently ignored for
    /// missing files so callers can fire-and-forget after writing.
    static func apply(to fileURL: URL) {
        apply(protectionType, to: fileURL)
    }

    static func applyAndVerify(to fileURL: URL) throws {
        let fm = FileManager.default
        try fm.setAttributes(
            [.protectionKey: protectionType],
            ofItemAtPath: fileURL.path
        )
        #if !targetEnvironment(simulator)
        let attributes = try fm.attributesOfItem(atPath: fileURL.path)
        guard let actual = attributes[.protectionKey] as? FileProtectionType,
              actual == protectionType else {
            throw CocoaError(.fileWriteUnknown)
        }
        #endif
    }

    /// Apply the weaker in-flight class to a transient pipeline artifact.
    static func applyInFlight(to fileURL: URL) {
        apply(inFlightProtectionType, to: fileURL)
    }

    private static func apply(_ type: FileProtectionType, to fileURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            try fm.setAttributes(
                [.protectionKey: type],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLog.recorder.atError.error(
                "protection: failed to set on \(fileURL.lastPathComponent, privacy: .public) code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
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
                    if fm.contentsEqual(atPath: legacy.path, andPath: destination.path) {
                        try? fm.removeItem(at: legacy)
                    } else {
                        RecordingQuarantine.quarantine(fileAt: legacy, reason: .legacyCollision)
                    }
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
                        "protection: migrate failed for \(legacy.lastPathComponent, privacy: .public) code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
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

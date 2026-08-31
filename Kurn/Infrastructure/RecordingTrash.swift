//
//  RecordingTrash.swift
//  Kurn
//
//  SwiftData and the filesystem are two stores with no shared transaction, so
//  "delete the audio file, then delete the model row" (the previous behavior
//  of `MeetingsViewModel.delete`/`deleteRecording`) has a window where the
//  audio is already gone but the row survives — a save failure or a process
//  death between the two leaves a visible meeting/recording pointing at
//  missing audio, with no way back.
//
//  This closes that window by making deletion move-then-purge instead of
//  delete-then-delete: every file is atomically moved into a protected trash
//  folder *before* the model mutation runs, and only purged once that
//  mutation is known to have committed. A synchronous save failure restores
//  immediately; a process death leaves a trash folder for `sweep(context:)`
//  to reconcile on the next launch or foreground activation.
//
//  Reconciliation does not have to infer intent from ambiguous state: a
//  `Recording` row is deleted inside the same `ModelContext.save()` call that
//  makes its trashed files eligible for purge, and that save is itself
//  atomic. So a trashed file's row either still exists (the mutation never
//  committed — restore) or it does not (the mutation committed — purge).
//  There is no third state to guess at.
//

import Foundation
import SwiftData

enum RecordingTrash {
    /// Where `AudioFileStore.delete(fileName:)` looks for a file, in the same
    /// order — mirrored here so a moved file always knows where it came from
    /// and can be put back exactly there.
    private enum SourceDirectory: String, CaseIterable {
        case main, enhanced, legacy

        var url: URL {
            switch self {
            case .main: return AudioFileStore.recordingsDirectoryURL
            case .enhanced: return AudioFileStore.enhancedDirectoryPath
            case .legacy: return AudioFileStore.documentsURL
            }
        }
    }

    private static var trashRootURL: URL {
        AudioFileStore.recordingsDirectoryURL
            .appendingPathComponent(RecordingProtection.trashDirectoryName, isDirectory: true)
    }

    private static func operationDirectory(_ operationID: UUID) -> URL {
        trashRootURL.appendingPathComponent(operationID.uuidString, isDirectory: true)
    }

    /// Atomically moves every on-disk copy of each name in `fileNames`
    /// (original and any derived enhanced copy, wherever either currently
    /// lives) into a protected trash folder identified by `operationID`.
    ///
    /// A file that does not exist in a given location is silently skipped,
    /// matching `AudioFileStore.delete`. A move that fails for any other
    /// reason (e.g. no room to create the trash subdirectory) is also
    /// skipped rather than thrown: leaving that copy in place — an orphan
    /// the user can still recover — is preferable to losing it outright
    /// because the trash step itself couldn't complete. Callers proceed with
    /// the model mutation regardless of the return value.
    @discardableResult
    static func trash(fileNames: [String], operationID: UUID) -> Bool {
        let fm = FileManager.default
        var movedAny = false
        for fileName in fileNames {
            for source in SourceDirectory.allCases {
                let sourceURL = source.url.appendingPathComponent(fileName)
                guard fm.fileExists(atPath: sourceURL.path) else { continue }
                guard let destinationDirectory = try? RecordingProtection.ensureProtectedDirectory(
                    named: source.rawValue,
                    in: operationDirectory(operationID)
                ) else { continue }
                let destinationURL = destinationDirectory.appendingPathComponent(fileName)
                guard (try? fm.moveItem(at: sourceURL, to: destinationURL)) != nil else { continue }
                RecordingProtection.apply(to: destinationURL)
                movedAny = true
            }
        }
        return movedAny
    }

    /// The retryable purge step: permanently removes a trash folder once its
    /// model mutation is known to have committed. A no-op when nothing was
    /// ever trashed for this `operationID`.
    static func purge(operationID: UUID) {
        try? FileManager.default.removeItem(at: operationDirectory(operationID))
    }

    /// Moves every file in `operationID`'s trash folder back to where it came
    /// from, then removes the now-empty folder. Used both for a synchronous
    /// save failure (restore immediately) and by `sweep(context:)` (restore
    /// on the next launch after a mid-flight process death).
    static func restore(operationID: UUID) {
        let fm = FileManager.default
        let opDirectory = operationDirectory(operationID)
        for source in SourceDirectory.allCases {
            let sourceDirectory = opDirectory.appendingPathComponent(source.rawValue, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            for url in items {
                let destinationURL = source.url.appendingPathComponent(url.lastPathComponent)
                try? fm.moveItem(at: url, to: destinationURL)
                RecordingProtection.apply(to: destinationURL)
            }
        }
        try? fm.removeItem(at: opDirectory)
    }

    /// Launch/foreground reconciliation for trash folders left over by a
    /// process that died between `trash(fileNames:operationID:)` and this
    /// operation's `purge`/`restore`. Safe to call unconditionally.
    static func sweep(context: ModelContext) {
        let fm = FileManager.default
        guard let operationFolders = try? fm.contentsOfDirectory(
            at: trashRootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        guard !operationFolders.isEmpty else { return }
        guard let existingRecordings = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let knownFileNames = Set(existingRecordings.map(\.fileName))

        for folder in operationFolders {
            guard let operationID = UUID(uuidString: folder.lastPathComponent) else { continue }
            if containsAnyFile(in: folder, matching: knownFileNames) {
                restore(operationID: operationID)
            } else {
                purge(operationID: operationID)
            }
        }
    }

    private static func containsAnyFile(in operationFolder: URL, matching knownFileNames: Set<String>) -> Bool {
        let fm = FileManager.default
        for source in SourceDirectory.allCases {
            let sourceDirectory = operationFolder.appendingPathComponent(source.rawValue, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            if items.contains(where: { knownFileNames.contains($0.lastPathComponent) }) { return true }
        }
        return false
    }
}

//
//  ModelStoreBackupManager.swift
//  Kurn
//
//  H2 PR 4 (docs/resilience-megaplan.md): protected, bounded-generation
//  backups of the SwiftData store, taken before every open attempt so a
//  migration always has a known-good copy behind it, plus restore and a
//  quarantine mechanism that makes both restore and "confirmed fresh start"
//  undoable rather than destructive.
//
//  Every mutating operation here is additive-safe by construction: backup
//  only ever *copies* the live store (never touches it), pruning only ever
//  deletes redundant backup copies (never the live store, never a retained
//  generation), and both restore and fresh-start *move* the live store into
//  quarantine before replacing it — the pre-operation bytes are always
//  still on disk afterward, just relocated. Nothing in this file deletes an
//  original.
//

import Foundation

/// One backup generation's identity and provenance. `id` is the folder name
/// under the backups directory.
struct ModelStoreBackupGeneration: Sendable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    let schemaVersion: String
    let appVersion: String
    let appBuild: String
}

enum ModelStoreBackupError: Error {
    case generationNotFound(String)
}

private struct ModelStoreBackupMetadata: Codable {
    var createdAt: Date
    var schemaVersion: String
    var appVersion: String
    var appBuild: String
}

struct ModelStoreBackupManager {
    /// How many backup generations to retain; older ones are pruned after
    /// each new backup. Chosen to cover "the last few launches", not a long
    /// history — this is a pre-migration safety net, not a version archive.
    static let maxGenerations = 3

    let appSupportDirectory: URL
    private let fileManager: FileManager

    init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.appSupportDirectory = appSupportDirectory
        self.fileManager = fileManager
    }

    private var rootDirectory: URL {
        appSupportDirectory.appendingPathComponent("StoreRecovery", isDirectory: true)
    }
    private var backupsDirectory: URL {
        rootDirectory.appendingPathComponent("Backups", isDirectory: true)
    }
    private var quarantineDirectory: URL {
        rootDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    private var liveStoreFileNames: [String] {
        [""] + ModelStoreProtection.sidecarSuffixes
    }

    private func liveStoreFiles() -> [URL] {
        liveStoreFileNames
            .map { appSupportDirectory.appendingPathComponent(ModelStoreProtection.baseName + $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Copies whichever live store files currently exist into a brand-new,
    /// protected backup generation, then prunes generations beyond
    /// `maxGenerations`. Returns `nil` (not an error) when there is nothing
    /// to back up yet — a fresh install, or the very first launch before
    /// `ModelContainer` has created the store file.
    @discardableResult
    func createBackupIfLiveStoreExists() throws -> ModelStoreBackupGeneration? {
        let sources = liveStoreFiles()
        guard !sources.isEmpty else { return nil }

        // Rate-limited to at most once per app version+build, not once per
        // launch: a migration can only be triggered by a new schema, which
        // can only ship in a new app version, so the newest generation
        // already covers "before this version's migration" once it exists.
        // Without this, every ordinary launch would copy the entire store —
        // meaningful disk I/O for a large library with nothing to protect
        // against that the last backup doesn't already cover.
        if let newest = listGenerations().first,
           newest.appVersion == Self.appVersion, newest.appBuild == Self.appBuild {
            return nil
        }

        try RecordingProtection.ensureProtectedDirectory(named: "StoreRecovery", in: appSupportDirectory)
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let generationID = Self.makeGenerationID()
        let destination = backupsDirectory.appendingPathComponent(generationID, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for source in sources {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            try fileManager.copyItem(at: source, to: target)
            try RecordingProtection.applyAndVerify(to: target)
        }

        let metadata = ModelStoreBackupMetadata(
            createdAt: Date(),
            schemaVersion: Self.currentSchemaVersionString,
            appVersion: Self.appVersion,
            appBuild: Self.appBuild
        )
        try write(metadata, to: destination)
        try pruneOldGenerations(keeping: Self.maxGenerations)

        return ModelStoreBackupGeneration(
            id: generationID,
            createdAt: metadata.createdAt,
            schemaVersion: metadata.schemaVersion,
            appVersion: metadata.appVersion,
            appBuild: metadata.appBuild
        )
    }

    /// All backup generations, newest first.
    func listGenerations() -> [ModelStoreBackupGeneration] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .compactMap { folder -> ModelStoreBackupGeneration? in
                guard let metadata = readMetadata(at: folder) else { return nil }
                return ModelStoreBackupGeneration(
                    id: folder.lastPathComponent,
                    createdAt: metadata.createdAt,
                    schemaVersion: metadata.schemaVersion,
                    appVersion: metadata.appVersion,
                    appBuild: metadata.appBuild
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes the oldest generations beyond `keeping`. The only deletion in
    /// this type, and it only ever removes redundant backup copies.
    func pruneOldGenerations(keeping: Int) throws {
        let generations = listGenerations()
        guard generations.count > keeping else { return }
        for stale in generations.dropFirst(keeping) {
            try? fileManager.removeItem(at: backupsDirectory.appendingPathComponent(stale.id, isDirectory: true))
        }
    }

    /// Moves the current live store files aside into a uniquely-named
    /// quarantine folder — a move, never a delete. Returns `nil` when there
    /// is nothing live to quarantine.
    @discardableResult
    func quarantineLiveStore() throws -> URL? {
        let sources = liveStoreFiles()
        guard !sources.isEmpty else { return nil }

        try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        let destination = quarantineDirectory.appendingPathComponent(Self.makeGenerationID(), isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for source in sources {
            try fileManager.moveItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
        }
        return destination
    }

    /// Restores `generation` over the live store location. The pre-restore
    /// live store, if any, is quarantined first — restoring is itself
    /// undoable, not a one-way overwrite.
    func restore(generation: ModelStoreBackupGeneration) throws {
        let source = backupsDirectory.appendingPathComponent(generation.id, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else {
            throw ModelStoreBackupError.generationNotFound(generation.id)
        }
        try quarantineLiveStore()
        for suffix in liveStoreFileNames {
            let sourceFile = source.appendingPathComponent(ModelStoreProtection.baseName + suffix)
            guard fileManager.fileExists(atPath: sourceFile.path) else { continue }
            let destinationFile = appSupportDirectory.appendingPathComponent(ModelStoreProtection.baseName + suffix)
            try fileManager.copyItem(at: sourceFile, to: destinationFile)
            try RecordingProtection.applyAndVerify(to: destinationFile)
        }
    }

    private func write(_ metadata: ModelStoreBackupMetadata, to folder: URL) throws {
        let url = folder.appendingPathComponent("metadata.json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
        RecordingProtection.apply(to: url)
    }

    private func readMetadata(at folder: URL) -> ModelStoreBackupMetadata? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")) else { return nil }
        return try? JSONDecoder().decode(ModelStoreBackupMetadata.self, from: data)
    }

    private static func makeGenerationID() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(UUID().uuidString.prefix(8))"
    }

    private static var currentSchemaVersionString: String {
        "\(KurnSchemaV1.versionIdentifier)"
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }
}

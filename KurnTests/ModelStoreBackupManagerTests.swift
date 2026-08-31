//
//  ModelStoreBackupManagerTests.swift
//  KurnTests
//
//  Exercises the H2 PR 4 backup/restore/quarantine engine
//  (docs/resilience-megaplan.md) against a real temporary directory —
//  synthetic "live store" files rather than a real SwiftData store, since
//  this type only ever copies/moves whole files and never opens them. Proves
//  the acceptance bar directly: backup only ever copies, pruning only ever
//  removes redundant generations, and restore/quarantine never delete an
//  original — they move it aside.
//

import Foundation
import Testing
@testable import Kurn

struct ModelStoreBackupManagerTests {

    private func withTempAppSupport(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreBackupManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// Writes synthetic store + sidecar files so this test never depends on
    /// a real SwiftData/SQLite file being present.
    private func writeLiveStoreFiles(in directory: URL, content: String) throws {
        for suffix in [""] + ModelStoreProtection.sidecarSuffixes {
            let url = directory.appendingPathComponent(ModelStoreProtection.baseName + suffix)
            try content.data(using: .utf8)?.write(to: url)
        }
    }

    private func readLiveStoreContent(in directory: URL) -> String? {
        let url = directory.appendingPathComponent(ModelStoreProtection.baseName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @Test func returnsNilWhenThereIsNoLiveStoreToBackUp() throws {
        try withTempAppSupport { directory in
            let manager = ModelStoreBackupManager(appSupportDirectory: directory)
            let generation = try manager.createBackupIfLiveStoreExists()
            #expect(generation == nil)
            #expect(manager.listGenerations().isEmpty)
        }
    }

    @Test func backsUpAllLiveStoreFilesAndListsTheGeneration() throws {
        try withTempAppSupport { directory in
            try writeLiveStoreFiles(in: directory, content: "v1")
            let manager = ModelStoreBackupManager(appSupportDirectory: directory)

            let generation = try manager.createBackupIfLiveStoreExists()

            #expect(generation != nil)
            let generations = manager.listGenerations()
            #expect(generations.count == 1)
            #expect(generations.first?.id == generation?.id)
            // The live files must be untouched — backup only ever copies.
            #expect(readLiveStoreContent(in: directory) == "v1")
        }
    }

    @Test func secondBackupInTheSameAppVersionIsRateLimited() throws {
        try withTempAppSupport { directory in
            try writeLiveStoreFiles(in: directory, content: "v1")
            let manager = ModelStoreBackupManager(appSupportDirectory: directory)

            let first = try manager.createBackupIfLiveStoreExists()
            let second = try manager.createBackupIfLiveStoreExists()

            #expect(first != nil)
            #expect(second == nil)
            #expect(manager.listGenerations().count == 1)
        }
    }

    @Test func pruneOldGenerationsKeepsOnlyTheNewestAndNeverTouchesTheLiveStore() throws {
        try withTempAppSupport { directory in
            try writeLiveStoreFiles(in: directory, content: "live")
            let manager = ModelStoreBackupManager(appSupportDirectory: directory)

            // Three distinct generations, bypassing the rate limit by writing
            // metadata files directly with distinct fabricated app versions —
            // pruning must not care why a generation exists, only how many.
            for index in 0..<3 {
                try writeLiveStoreFiles(in: directory, content: "live")
                let created = try manager.createBackupIfLiveStoreExists()
                let generation = try #require(created)
                // Force the next call to not be rate-limited by rewriting
                // that generation's metadata with a different app version.
                try rewriteAppVersion(of: generation, in: directory, to: "fabricated-\(index)")
            }

            try manager.pruneOldGenerations(keeping: 1)

            #expect(manager.listGenerations().count == 1)
            #expect(readLiveStoreContent(in: directory) == "live")
        }
    }

    @Test func restoreQuarantinesTheLiveStoreInsteadOfDeletingItAndCopiesTheBackupIn() throws {
        try withTempAppSupport { directory in
            try writeLiveStoreFiles(in: directory, content: "original")
            let manager = ModelStoreBackupManager(appSupportDirectory: directory)
            let created = try manager.createBackupIfLiveStoreExists()
            let generation = try #require(created)

            // Simulate the live store having moved on since the backup was
            // taken (e.g. new meetings recorded).
            try writeLiveStoreFiles(in: directory, content: "changed-after-backup")

            try manager.restore(generation: generation)

            #expect(readLiveStoreContent(in: directory) == "original")
            let quarantined = quarantinedContents(in: directory)
            #expect(quarantined.contains("changed-after-backup"))
        }
    }

    @Test func quarantineLiveStoreIsANoOpWhenNothingIsLive() throws {
        try withTempAppSupport { directory in
            let manager = ModelStoreBackupManager(appSupportDirectory: directory)
            let quarantinedURL = try manager.quarantineLiveStore()
            #expect(quarantinedURL == nil)
        }
    }

    // MARK: - Helpers

    private func rewriteAppVersion(of generation: ModelStoreBackupGeneration, in directory: URL, to version: String) throws {
        let metadataURL = directory
            .appendingPathComponent("StoreRecovery", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(generation.id, isDirectory: true)
            .appendingPathComponent("metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)
        let parsed = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        var json = try #require(parsed)
        json["appVersion"] = version
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func quarantinedContents(in directory: URL) -> [String] {
        let quarantineRoot = directory
            .appendingPathComponent("StoreRecovery", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: quarantineRoot, includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return folders.flatMap { folder -> [String] in
            let storeFile = folder.appendingPathComponent(ModelStoreProtection.baseName)
            guard let data = try? Data(contentsOf: storeFile) else { return [] }
            return [String(data: data, encoding: .utf8) ?? ""]
        }
    }
}

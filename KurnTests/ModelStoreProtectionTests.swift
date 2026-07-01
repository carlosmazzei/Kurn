//
//  ModelStoreProtectionTests.swift
//  KurnTests
//
//  As with RecordingProtectionTests, the simulator/macOS doesn't enforce
//  FileProtectionType at the filesystem level, so these tests assert the
//  calls do not throw and don't disturb files that exist, rather than
//  observing the protection class itself.
//

import Foundation
import Testing
@testable import Kurn

struct ModelStoreProtectionTests {

    @Test func applyOnFreshInstallWithNoStoreFilesIsSilentlyIgnored() throws {
        let parent = try Self.makeTempParent()
        defer { try? FileManager.default.removeItem(at: parent) }

        ModelStoreProtection.apply(appSupportOverride: parent)
    }

    @Test func applyLeavesExistingStoreFilesIntact() throws {
        let parent = try Self.makeTempParent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let base = parent.appendingPathComponent(ModelStoreProtection.baseName)
        let shm = parent.appendingPathComponent(ModelStoreProtection.baseName + "-shm")
        FileManager.default.createFile(atPath: base.path, contents: Data("store".utf8))
        FileManager.default.createFile(atPath: shm.path, contents: Data("shm".utf8))

        ModelStoreProtection.apply(appSupportOverride: parent)

        #expect(try Data(contentsOf: base) == Data("store".utf8))
        #expect(try Data(contentsOf: shm) == Data("shm".utf8))
    }

    private static func makeTempParent() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurn-store-protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

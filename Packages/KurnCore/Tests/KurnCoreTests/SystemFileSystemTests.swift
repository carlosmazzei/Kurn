//
//  SystemFileSystemTests.swift
//  KurnCoreTests
//
//  Exercises the real `SystemFileSystem` adapter against a genuine scratch
//  directory (safe on Linux, no simulator needed) — the fakes conforming to
//  `FileSystem` live in the app's own test target instead, since that's
//  where the seam's first consumer (`TempFileCleaner`) lives.
//

import Foundation
import Testing
@testable import KurnCore

struct SystemFileSystemTests {

    @Test func listsAndRemovesRealFiles() throws {
        let fileSystem = SystemFileSystem()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KurnCoreFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("sample.txt")
        try Data("hello".utf8).write(to: file)

        let listed = try fileSystem.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        )
        #expect(listed.map(\.lastPathComponent) == ["sample.txt"])

        try fileSystem.removeItem(at: file)
        let afterRemoval = try fileSystem.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        )
        #expect(afterRemoval.isEmpty)
    }

    @Test func removingAMissingFileThrows() {
        let fileSystem = SystemFileSystem()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("KurnCoreFileSystemTests-missing-\(UUID().uuidString).txt")
        #expect(throws: Error.self) {
            try fileSystem.removeItem(at: missing)
        }
    }
}

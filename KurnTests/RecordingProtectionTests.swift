//
//  RecordingProtectionTests.swift
//  KurnTests
//
//  Exercises directory creation, attribute application, and the legacy-files
//  migration path. The simulator (and macOS) does not enforce
//  `FileProtectionType` at the filesystem level, so these tests do not assert
//  the protection class is observable — they assert the calls do not throw,
//  the directory exists, and the migration moves files correctly. The
//  protection behavior itself is verified manually on a real device.
//

import Foundation
import Testing
@testable import Kurn

struct RecordingProtectionTests {

    @Test func ensureProtectedDirectoryCreatesAndIsIdempotent() throws {
        let parent = try Self.makeTempParent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let url = try RecordingProtection.ensureProtectedDirectory(at: parent)
        #expect(url.lastPathComponent == RecordingProtection.directoryName)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Second call must not throw and must return the same URL.
        let again = try RecordingProtection.ensureProtectedDirectory(at: parent)
        #expect(again == url)
    }

    @Test func applyOnMissingFileIsSilentlyIgnored() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")
        RecordingProtection.apply(to: url)
    }

    @Test func migrationMovesLegacyFilesIntoTheRecordingsDirectory() throws {
        let parent = try Self.makeTempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let recordings = try RecordingProtection.ensureProtectedDirectory(at: parent)

        let fileName = "abc_20260630T120000.m4a"
        let legacy = parent.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: legacy.path, contents: Data("legacy".utf8))

        RecordingProtection.migrateLegacyRecordings(
            documentsURL: parent,
            recordingsURL: recordings
        )

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: recordings.appendingPathComponent(fileName).path))
    }

    @Test func migrationIsIdempotent() throws {
        let parent = try Self.makeTempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let recordings = try RecordingProtection.ensureProtectedDirectory(at: parent)

        let fileName = "abc_20260630T120000.m4a"
        let legacy = parent.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: legacy.path, contents: Data("legacy".utf8))

        RecordingProtection.migrateLegacyRecordings(documentsURL: parent, recordingsURL: recordings)
        RecordingProtection.migrateLegacyRecordings(documentsURL: parent, recordingsURL: recordings)

        let destinationContents = try Data(contentsOf: recordings.appendingPathComponent(fileName))
        #expect(destinationContents == Data("legacy".utf8))
    }

    @Test func migrationRemovesLegacyWhenDestinationAlreadyExists() throws {
        let parent = try Self.makeTempParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let recordings = try RecordingProtection.ensureProtectedDirectory(at: parent)

        let fileName = "abc_20260630T120000.m4a"
        let legacy = parent.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: legacy.path, contents: Data("stale".utf8))
        FileManager.default.createFile(
            atPath: recordings.appendingPathComponent(fileName).path,
            contents: Data("current".utf8)
        )

        RecordingProtection.migrateLegacyRecordings(documentsURL: parent, recordingsURL: recordings)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let kept = try Data(contentsOf: recordings.appendingPathComponent(fileName))
        #expect(kept == Data("current".utf8))
    }

    private static func makeTempParent() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurn-protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

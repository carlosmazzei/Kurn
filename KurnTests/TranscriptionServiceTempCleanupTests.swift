//
//  TranscriptionServiceTempCleanupTests.swift
//  KurnTests
//
//  Verifies the launch/run-time sweep of orphaned temporary files created by
//  earlier killed or failed transcriptions.
//

import Foundation
import Testing
@testable import Kurn

struct TranscriptionServiceTempCleanupTests {

    @Test func cleanupOrphanedTempFilesRemovesOldFilesAndKeepsNewOnes() throws {
        let tmp = FileManager.default.temporaryDirectory
        let oldPrefix = "kurn_clean_"
        let oldName = "\(oldPrefix)\(UUID().uuidString).m4a"
        let oldURL = tmp.appendingPathComponent(oldName)
        let newName = "\(oldPrefix)\(UUID().uuidString).m4a"
        let newURL = tmp.appendingPathComponent(newName)
        let otherPrefix = "kurn_diar_"
        let otherName = "\(otherPrefix)\(UUID().uuidString).wav"
        let otherURL = tmp.appendingPathComponent(otherName)

        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
            try? FileManager.default.removeItem(at: otherURL)
        }

        try Data([0x01]).write(to: oldURL)
        try Data([0x02]).write(to: newURL)
        try Data([0x03]).write(to: otherURL)

        // Make the "old" file look like it was created 2 hours ago.
        let oldDate = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.creationDate: oldDate],
            ofItemAtPath: oldURL.path
        )

        TranscriptionService.cleanupOrphanedTempFiles()

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(FileManager.default.fileExists(atPath: otherURL.path))
    }

    @Test func cleanupOrphanedTempFilesRemovesOldUploadBodies() throws {
        let uploadDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperUploadBodies", isDirectory: true)
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)

        let oldBody = uploadDir.appendingPathComponent("\(UUID().uuidString).multipart")
        let newBody = uploadDir.appendingPathComponent("\(UUID().uuidString).multipart")
        defer {
            try? FileManager.default.removeItem(at: oldBody)
            try? FileManager.default.removeItem(at: newBody)
        }

        try Data([0x01]).write(to: oldBody)
        try Data([0x02]).write(to: newBody)

        let oldDate = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.creationDate: oldDate],
            ofItemAtPath: oldBody.path
        )

        TranscriptionService.cleanupOrphanedTempFiles()

        #expect(!FileManager.default.fileExists(atPath: oldBody.path))
        #expect(FileManager.default.fileExists(atPath: newBody.path))
    }
}

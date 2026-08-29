//
//  TempFileCleanerFaultTests.swift
//  KurnTests
//
//  Proves the `FileSystem` seam end to end against real production code:
//  `TempFileCleaner.forceCleanup()` today logs and continues when a removal
//  fails (it never propagates the error), and a `FakeFileSystem` lets this
//  test provoke that failure deterministically instead of needing a real,
//  hard-to-arrange filesystem error.
//

import Foundation
import Testing
@testable import Kurn

struct TempFileCleanerFaultTests {

    @Test func forceCleanupSurvivesARemovalFailure() {
        let tmp = FileManager.default.temporaryDirectory
        let orphan = tmp.appendingPathComponent("kurn_clean_orphan.pcm")
        let uploadDir = tmp.appendingPathComponent("WhisperUploadBodies", isDirectory: true)

        let fileSystem = FakeFileSystem()
        fileSystem.setContents([orphan], of: tmp)
        fileSystem.setContents([], of: uploadDir)
        fileSystem.failRemoval(of: orphan)

        // Must not crash or throw despite the injected failure — this is
        // the seam proving itself, not a behavior change: `forceCleanup`
        // already logs-and-continues on a real removal error today.
        let result = TempFileCleaner.forceCleanup(fileSystem: fileSystem)

        #expect(result.files == 0)
        #expect(result.bytes == 0)
        #expect(fileSystem.removalAttempts == [orphan])
    }
}

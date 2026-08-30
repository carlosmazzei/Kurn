import Foundation
import Testing
@testable import Kurn

struct RecordingFileFinalizerTests {
    @Test func missingFileIsRejected() {
        let fileName = "missing-\(UUID().uuidString).m4a"
        #expect(throws: RecordingFileFinalizationError.missing) {
            try RecordingFileFinalizer().finalize(fileName: fileName)
        }
    }

    @Test func emptyFileIsRejected() throws {
        let fileName = "empty-\(UUID().uuidString).m4a"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try Data().write(to: url)
        defer { AudioFileStore.delete(fileName: fileName) }

        #expect(throws: RecordingFileFinalizationError.empty) {
            try RecordingFileFinalizer().finalize(fileName: fileName)
        }
    }

    @Test func protectionFailureRejectsOtherwiseReadableFile() throws {
        let fileName = "unprotected-\(UUID().uuidString).m4a"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1, at: url)
        defer { AudioFileStore.delete(fileName: fileName) }
        let finalizer = RecordingFileFinalizer { _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        #expect(throws: RecordingFileFinalizationError.protectionFailed) {
            try finalizer.finalize(fileName: fileName)
        }
    }

    @Test func readableFileReturnsAuthoritativeMetadata() throws {
        let fileName = "valid-\(UUID().uuidString).m4a"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        try AudioFixtures.m4aTone(seconds: 1, at: url)
        defer { AudioFileStore.delete(fileName: fileName) }

        let result = try RecordingFileFinalizer().finalize(fileName: fileName)

        #expect(result.fileSize > 0)
        #expect(result.duration > 0.9)
        #expect(result.duration < 1.1)
    }
}

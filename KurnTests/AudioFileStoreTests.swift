//
//  AudioFileStoreTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct AudioFileStoreTests {

    @Test func fileNameEmbedsMeetingIDAndTimestamp() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 0)
        let name = AudioFileStore.fileName(meetingID: id, date: date)
        #expect(name.hasPrefix(id.uuidString))
        #expect(name.hasSuffix(".m4a"))
        #expect(name == "\(id.uuidString)_\(date.fileTimestamp).m4a")
    }

    @Test func deleteOfMissingFileDoesNotThrowOrCrash() {
        AudioFileStore.delete(fileName: "does-not-exist-\(UUID().uuidString).m4a")
    }

    @Test func formattedSizeProducesHumanReadableString() {
        let value = AudioFileStore.formattedSize(1_500_000)
        #expect(!value.isEmpty)
        #expect(value != "0")
    }

    @Test func formattedSizeOfZeroIsNotNegative() {
        let value = AudioFileStore.formattedSize(0)
        #expect(!value.contains("-"))
    }

    /// Callers treat 0 as "unknown", so a missing file must report 0 rather
    /// than trapping — `RecordingRecovery`'s backfill relies on that.
    @Test func byteSizeOfMissingFileIsZero() {
        #expect(AudioFileStore.byteSize(fileName: "does-not-exist-\(UUID().uuidString).m4a") == 0)
    }

    @Test func byteSizeReportsTheBytesOnDisk() throws {
        let fileName = "kurn-test-\(UUID().uuidString).m4a"
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: url)
        defer { AudioFileStore.delete(fileName: fileName) }

        #expect(AudioFileStore.byteSize(fileName: fileName) == Int64(payload.count))
    }
}

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
}

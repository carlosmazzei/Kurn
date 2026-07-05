//
//  AudioChunkerTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct AudioChunkerTests {

    @Test func chunkReturnsOriginalFileUnmodifiedWhenUnderThresholds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data(repeating: 0, count: 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunker = AudioChunker()
        let chunks = try await chunker.chunk(url: url)

        #expect(chunks.count == 1)
        #expect(chunks[0].url == url)
        #expect(chunks[0].offset == 0)
    }

    @Test func longAudioUnderSizeThresholdIsSplitByDuration() async throws {
        // A non-zero tone, not silence: exporting a pure-silence AAC source
        // through AVAssetExportSession can yield an empty output file on some
        // AVFoundation versions, which isn't what this test is exercising.
        let url = try AudioFixtures.m4aTone(hz: 220, amplitude: 0.1, seconds: 15 * 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try await AudioChunker().chunk(url: url)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.offset >= 0 })
    }

    @Test func cleanupOnlyRemovesFilesInsideTemporaryDirectory() async throws {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0x01]).write(to: tmpURL)

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0x02]).write(to: documentsURL)
        defer { try? FileManager.default.removeItem(at: documentsURL) }

        let chunker = AudioChunker()
        await chunker.cleanup([
            AudioChunker.Chunk(url: tmpURL, offset: 0),
            AudioChunker.Chunk(url: documentsURL, offset: 10)
        ])

        #expect(!FileManager.default.fileExists(atPath: tmpURL.path))
        #expect(FileManager.default.fileExists(atPath: documentsURL.path))
    }

    @Test func realAudioUnderThresholdIsReturnedAsSingleChunk() async throws {
        let url = try AudioFixtures.m4aTone(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try await AudioChunker().chunk(url: url)
        #expect(chunks.count == 1)
        #expect(chunks[0].url == url)
        #expect(chunks[0].offset == 0)
    }

    @Test func cleanupWithEmptyListDoesNothing() async {
        // Should be a safe no-op (e.g. when transcription bailed before chunking).
        await AudioChunker().cleanup([])
    }

    @Test func chunkCleanupRemovesAllExportedTempFiles() async throws {
        // Non-zero tone; see comment in longAudioUnderSizeThresholdIsSplitByDuration().
        let url = try AudioFixtures.m4aTone(hz: 220, amplitude: 0.1, seconds: 15 * 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunker = AudioChunker()
        let chunks = try await chunker.chunk(url: url)
        #expect(chunks.count > 1)

        for chunk in chunks {
            #expect(FileManager.default.fileExists(atPath: chunk.url.path))
        }

        await chunker.cleanup(chunks)

        for chunk in chunks {
            #expect(!FileManager.default.fileExists(atPath: chunk.url.path))
        }
    }
}

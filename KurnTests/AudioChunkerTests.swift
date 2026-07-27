//
//  AudioChunkerTests.swift
//  KurnTests
//
//  Tests that export real chunks take `tempFileTestLock`, like the other suites
//  that touch the shared temporary directory. `AudioChunker` writes its chunks
//  as `kurn_chunk_*` there, and `TempFileCleaner.forceCleanup()` — exercised by
//  `TempFileCleanerTests` — deletes every file with that prefix regardless of
//  age. Without the lock the two suites interleave, the cleaner sweeps chunks
//  this suite is about to assert on, and the failure looks like an export bug.
//

import AVFoundation
import Foundation
import Testing
@testable import Kurn

struct AudioChunkerTests {

    /// 16 kHz mono audio — the shape the pipeline actually chunks, since
    /// `AudioPreprocessor` renders to 16 kHz mono before this runs. The codec
    /// picks the bit rate: AAC rejects the fixture's usual 64 kbps at this
    /// sample rate.
    private static func lowRateFixture(seconds: Double = fixtureSeconds) throws -> URL {
        try AudioFixtures.m4aTone(seconds: seconds, sampleRate: 16_000, bitRate: nil)
    }

    /// Long enough that per-chunk MP4 container overhead is a small share of a
    /// chunk — otherwise the byte-ratio assertion below measures the container
    /// rather than the audio. Three chunks, and about a second to run.
    private static let fixtureSeconds: Double = 30
    private static let fixtureChunkDuration: TimeInterval = 10

    private static func byteSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func duration(_ url: URL) async -> TimeInterval {
        (try? await AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
    }

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
        try await tempFileTestLock.run {
            let url = try AudioFixtures.m4aTone(hz: 0, seconds: 15 * 60)
            defer { try? FileManager.default.removeItem(at: url) }

            let chunks = try await AudioChunker().chunk(url: url)
            #expect(chunks.count > 1)
            #expect(chunks.allSatisfy { $0.offset >= 0 })
        }
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

    // MARK: - Chunks slice rather than re-encode
    //
    // These three pin what the older assertions (counts, offsets, file existence)
    // could not see: chunking used a fixed export preset whose format had nothing
    // to do with the source, so it silently resampled 16 kHz mono audio up and
    // multiplied every chunk's size.

    /// A chunk must carry the source's own format. The fixed `AppleM4A` preset
    /// resamples up instead, which is the whole bug.
    @Test func chunksKeepTheSourceSampleRateAndChannelCount() async throws {
        try await tempFileTestLock.run {
            let url = try Self.lowRateFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            let chunker = AudioChunker(chunkDuration: Self.fixtureChunkDuration)
            let chunks = try await chunker.chunkByDuration(url: url)
            #expect(chunks.count > 1)

            for chunk in chunks {
                let file = try AVAudioFile(forReading: chunk.url)
                #expect(file.fileFormat.sampleRate == 16_000)
                #expect(file.fileFormat.channelCount == 1)
            }
            await chunker.cleanup(chunks)
        }
    }

    /// Slicing must not cost bytes. Copying compressed samples adds only per-chunk
    /// container overhead; re-encoding with the fixed preset overshoots this by
    /// several times, and every one of those bytes is uploaded to Whisper.
    @Test func chunksTogetherAreNotBiggerThanTheSource() async throws {
        try await tempFileTestLock.run {
            let url = try Self.lowRateFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let sourceBytes = Self.byteSize(url)
            #expect(sourceBytes > 0)

            let chunker = AudioChunker(chunkDuration: Self.fixtureChunkDuration)
            let chunks = try await chunker.chunkByDuration(url: url)
            #expect(chunks.count > 1)

            let totalBytes = chunks.reduce(Int64(0)) { $0 + Self.byteSize($1.url) }
            #expect(totalBytes <= Int64(Double(sourceBytes) * 1.5))
            await chunker.cleanup(chunks)
        }
    }

    /// No audio may be dropped on the way through. This also bounds the
    /// frame-boundary slop a passthrough export introduces: chunks are cut at AAC
    /// frame boundaries, so the total can differ slightly from the source without
    /// anything being lost.
    @Test func chunksTogetherCoverTheWholeSource() async throws {
        try await tempFileTestLock.run {
            let url = try Self.lowRateFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let sourceDuration = await Self.duration(url)
            #expect(sourceDuration > 0)

            let chunker = AudioChunker(chunkDuration: Self.fixtureChunkDuration)
            let chunks = try await chunker.chunkByDuration(url: url)
            #expect(chunks.count > 1)

            var total: TimeInterval = 0
            for chunk in chunks {
                total += await Self.duration(chunk.url)
            }
            // Strong on the low side — dropped audio is the failure that matters.
            // The upper bound is only a sanity check: each chunk file carries its
            // own AAC priming/padding, so a small overshoot is expected.
            #expect(total >= sourceDuration - 0.3)
            #expect(total <= sourceDuration + 1.0)
            await chunker.cleanup(chunks)
        }
    }

    @Test func chunkCleanupRemovesAllExportedTempFiles() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.m4aTone(hz: 0, seconds: 15 * 60)
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
}

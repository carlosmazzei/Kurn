//
//  VADAudioCompactorTests.swift
//  KurnTests
//
//  End-to-end `VADAudioCompactor.compact` and `prefixClip` on synthetic PCM
//  fixtures. The pure `remap`/`normalize` helpers are covered in
//  `RecognitionPipelineTests`; this file is about the streaming write path —
//  when compaction is declined, what the timeline map looks like when it
//  runs, and that temp output is cleaned up.
//

import AVFoundation
import Foundation
import KurnCore
import Testing
@testable import Kurn

struct VADAudioCompactorTests {

    /// Container duration via `AVURLAsset` rather than `AVAudioFile.read`: the
    /// simulator's AAC decode path is unreliable (see `OfflineAudioRenderer`),
    /// while the header is always readable.
    private func duration(of url: URL) async throws -> TimeInterval {
        CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
    }

    @Test func noRegionsDeclinesCompaction() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 3.0)])
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try await VADAudioCompactor().compact(url: url, regions: [])
            #expect(result == nil)
        }
    }

    @Test func speechCoveringTheWholeClipDeclinesCompaction() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 3.0)])
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try await VADAudioCompactor().compact(
                url: url,
                regions: [SpeechRegion(start: 0, end: 3.0)]
            )
            #expect(result == nil)
        }
    }

    @Test func savingsBelowThresholdDeclineCompaction() async throws {
        try await tempFileTestLock.run {
            // 3 s clip, 2.5 s speech (+ padding) -> well under a 1 s saving.
            let url = try AudioFixtures.wav(segments: [(440, 3.0)])
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try await VADAudioCompactor().compact(
                url: url,
                regions: [SpeechRegion(start: 0.2, end: 2.7)],
                minSavings: 1.0
            )
            #expect(result == nil)
        }
    }

    @Test func compactionDropsSilenceAndBuildsAMonotonicMap() async throws {
        try await tempFileTestLock.run {
            // tone 1 s | silence 4 s | tone 1 s
            let url = try AudioFixtures.wav(segments: [(440, 1.0), (0, 4.0), (440, 1.0)])
            defer { try? FileManager.default.removeItem(at: url) }
            let compactor = VADAudioCompactor()

            let result = try #require(try await compactor.compact(
                url: url,
                regions: [SpeechRegion(start: 0, end: 1.0), SpeechRegion(start: 5.0, end: 6.0)],
                pad: 0.1,
                gap: 0.1
            ))
            defer { compactor.cleanup(result.url) }

            #expect(FileManager.default.fileExists(atPath: result.url.path))
            #expect(result.map.count == 2)

            let first = result.map[0]
            let second = result.map[1]
            #expect(first.compactedStart == 0)
            #expect(first.originalStart == 0)
            #expect(abs(first.duration - 1.1) < 0.1)
            // Second region starts after the first plus the seam gap, and keeps its
            // original position so remapping back is exact.
            #expect(abs(second.compactedStart - (first.duration + 0.1)) < 0.05)
            #expect(abs(second.originalStart - 4.9) < 0.01)

            // ~2.2 s of speech + 0.1 s gap versus a 6 s original.
            let compacted = try await duration(of: result.url)
            #expect(compacted < 3.0)
            #expect(compacted > 1.5)

            // Times inside the compacted file map back into the original timeline.
            let remapped = VADAudioCompactor.remap(second.compactedStart + 0.5, map: result.map)
            #expect(abs(remapped - (second.originalStart + 0.5)) < 0.01)
        }
    }

    @Test func adjacentRegionsMergeIntoOneMapEntry() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 2.0), (0, 3.0)])
            defer { try? FileManager.default.removeItem(at: url) }
            let compactor = VADAudioCompactor()

            // Two regions whose padding overlaps are merged by `normalize`, so the
            // output has a single region and no seam gap.
            let result = try #require(try await compactor.compact(
                url: url,
                regions: [SpeechRegion(start: 0, end: 0.9), SpeechRegion(start: 1.0, end: 2.0)],
                pad: 0.2
            ))
            defer { compactor.cleanup(result.url) }

            #expect(result.map.count == 1)
            #expect(result.map[0].originalStart == 0)
        }
    }

    @Test func cleanupOnlyRemovesTemporaryFiles() throws {
        let compactor = VADAudioCompactor()

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0]).write(to: temp)
        compactor.cleanup(temp)
        #expect(!FileManager.default.fileExists(atPath: temp.path))

        let outside = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/\(UUID().uuidString).m4a")
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        compactor.cleanup(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func prefixClipReturnsNilForClipsAlreadyShortEnough() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 1.0)])
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(try VADAudioCompactor.prefixClip(url: url, seconds: 5) == nil)
        }
    }

    @Test func prefixClipWritesOnlyTheRequestedHead() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 4.0)])
            defer { try? FileManager.default.removeItem(at: url) }

            let clip = try #require(try VADAudioCompactor.prefixClip(url: url, seconds: 1.5))
            defer { try? FileManager.default.removeItem(at: clip) }

            #expect(clip.path.hasPrefix(FileManager.default.temporaryDirectory.path))
            // The AAC container's reported duration drifts by a few hundred ms
            // (priming/padding frames, estimated timescale); the point is that the
            // clip is a fraction of the 4 s source, not its exact length.
            let clipDuration = try await duration(of: clip)
            #expect(clipDuration > 1.0)
            #expect(clipDuration < 2.5)
        }
    }

    @Test func unreadableInputThrows() async throws {
        try await tempFileTestLock.run {
            let url = AudioFixtures.tempURL(ext: "m4a")
            try? Data("garbage".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            await #expect(throws: (any Error).self) {
                _ = try await VADAudioCompactor().compact(url: url, regions: [SpeechRegion(start: 0, end: 1)])
            }
        }
    }
}

//
//  PipelineDigestTests.swift
//  KurnTests
//
//  These digests are the identity checks H4 relies on to decide whether a
//  transcription checkpoint may resume: deterministic, sensitive to content
//  and order, and honest about failure (a missing/unreadable file throws
//  rather than silently hashing nothing).
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct PipelineDigestTests {

    @Test func fileDigestIsDeterministicForTheSameBytes() throws {
        let url = try makeTempFile(contents: Data("hello world".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try PipelineDigest.sha256Hex(ofFileAt: url)
        let second = try PipelineDigest.sha256Hex(ofFileAt: url)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test func fileDigestChangesWithContent() throws {
        let urlA = try makeTempFile(contents: Data("hello world".utf8))
        let urlB = try makeTempFile(contents: Data("hello worlD".utf8))
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        #expect(try PipelineDigest.sha256Hex(ofFileAt: urlA) != PipelineDigest.sha256Hex(ofFileAt: urlB))
    }

    @Test func fileDigestIsStableAcrossChunkSizes() throws {
        // A multi-chunk read must hash identically to a single-chunk read of
        // the same bytes — otherwise the digest would depend on an
        // implementation detail (buffer size) rather than file content.
        let bytes = Data((0..<5000).map { UInt8($0 % 256) })
        let url = try makeTempFile(contents: bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let wholeFile = try PipelineDigest.sha256Hex(ofFileAt: url, chunkSize: 1 << 20)
        let smallChunks = try PipelineDigest.sha256Hex(ofFileAt: url, chunkSize: 7)
        #expect(wholeFile == smallChunks)
    }

    @Test func fileDigestThrowsForMissingFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID()).m4a")
        #expect(throws: (any Error).self) {
            try PipelineDigest.sha256Hex(ofFileAt: missing)
        }
    }

    @Test func valuesDigestIsOrderSensitive() {
        let ascending = PipelineDigest.sha256Hex(of: [0, 600, 1200])
        let descending = PipelineDigest.sha256Hex(of: [1200, 600, 0])
        #expect(ascending != descending)
    }

    @Test func valuesDigestDistinguishesDifferentCutPointsWithSameCount() {
        // The whole point of the chunk-plan digest: two plans with the same
        // number of chunks can still be cut at different offsets.
        let planA = PipelineDigest.sha256Hex(of: [0, 600])
        let planB = PipelineDigest.sha256Hex(of: [0, 500])
        #expect(planA != planB)
    }

    @Test func segmentsDigestIsSensitiveToEveryField() {
        let base = [TimelineSegment(compactedStart: 0, originalStart: 0, duration: 10)]
        let differentCompactedStart = [TimelineSegment(compactedStart: 1, originalStart: 0, duration: 10)]
        let differentOriginalStart = [TimelineSegment(compactedStart: 0, originalStart: 1, duration: 10)]
        let differentDuration = [TimelineSegment(compactedStart: 0, originalStart: 0, duration: 11)]

        let baseDigest = PipelineDigest.sha256Hex(of: base)
        #expect(baseDigest != PipelineDigest.sha256Hex(of: differentCompactedStart))
        #expect(baseDigest != PipelineDigest.sha256Hex(of: differentOriginalStart))
        #expect(baseDigest != PipelineDigest.sha256Hex(of: differentDuration))
        #expect(baseDigest == PipelineDigest.sha256Hex(of: base))
    }

    private func makeTempFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bin")
        try contents.write(to: url)
        return url
    }
}

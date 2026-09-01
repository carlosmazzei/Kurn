//
//  PipelineDigest.swift
//  Kurn
//
//  SHA-256 helpers backing `TranscriptionPipelineFingerprint` (H4): hashing a
//  potentially multi-hour audio file, a VAD-compaction map, or a chunk plan
//  into a short string two runs can compare for exact identity. Lives in the
//  app target rather than `KurnCore` because it needs `CryptoKit`, which does
//  not exist on Linux — `KurnCore`'s whole point is compiling there.
//

import CryptoKit
import Foundation
import KurnCore

enum PipelineDigest {

    /// Hex SHA-256 of a file's bytes, read in fixed-size chunks so hashing a
    /// long recording never holds the whole thing in memory. Throws (rather
    /// than swallowing) on any read failure so a caller can tell "unreadable
    /// source" apart from "hashed successfully" instead of silently digesting
    /// a truncated prefix.
    static func sha256Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    /// Hex SHA-256 over an ordered list of time values (e.g. chunk-plan
    /// offsets). Order-sensitive: a reordered plan with the same offsets is a
    /// different plan.
    static func sha256Hex(of values: [TimeInterval]) -> String {
        var hasher = SHA256()
        for value in values {
            withUnsafeBytes(of: value.bitPattern) { hasher.update(bufferPointer: $0) }
        }
        return hex(hasher.finalize())
    }

    /// Hex SHA-256 over a VAD-compaction map's segments (compacted-timeline
    /// offset, original-timeline offset, and duration per segment).
    static func sha256Hex(of segments: [TimelineSegment]) -> String {
        var hasher = SHA256()
        for segment in segments {
            for value in [segment.compactedStart, segment.originalStart, segment.duration] {
                withUnsafeBytes(of: value.bitPattern) { hasher.update(bufferPointer: $0) }
            }
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

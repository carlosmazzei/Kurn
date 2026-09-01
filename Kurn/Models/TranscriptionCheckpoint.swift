//
//  TranscriptionCheckpoint.swift
//  Kurn
//
//  Durable progress of a chunked transcription, persisted on `Recording` (as
//  JSON Data) after every completed chunk. When a long transcription is
//  interrupted — the app is backgrounded past its grace window, killed, or the
//  user cancels — the next attempt re-derives the same pipeline and either
//  continues from `completedChunks` or, if anything about the run changed,
//  discards the checkpoint and starts over rather than risk splicing
//  incompatible chunks together (H4). `fingerprint` carries everything about
//  the run except the exact chunk plan (source identity, preprocessing, VAD,
//  language, engine/provider/model, and the VAD-compaction map); the plan
//  itself isn't known until chunking has actually run, so it lives in its own
//  `chunkPlanDigest` and is checked separately by `ChunkedTranscriptionRunner`.
//

import Foundation
import KurnCore

struct TranscriptionCheckpoint: Codable, Sendable {
    /// Everything about the pipeline configuration and source audio this run
    /// was produced from, except the exact chunk plan. See
    /// `TranscriptionPipelineFingerprint`.
    var fingerprint: TranscriptionPipelineFingerprint
    /// SHA-256 over the exact chunk plan's offsets that produced `spans`. A
    /// resume whose freshly re-derived plan hashes differently — a different
    /// chunk count, or the same count cut at different points — must not
    /// reuse these spans even though `fingerprint` alone still matches.
    var chunkPlanDigest: String
    /// Chunk count of the plan these spans belong to. A resume whose
    /// re-derived plan has a different count must start over; kept alongside
    /// `chunkPlanDigest` for cheap logging/progress display without decoding
    /// the digest's meaning.
    var totalChunks: Int
    /// Chunks fully transcribed so far; the resume starts at this index.
    var completedChunks: Int
    /// Language reported by the engine for the first chunk (may be empty).
    var detectedLanguage: String
    /// Spans of every completed chunk, already offset to the input's timeline.
    var spans: [Span]

    struct Span: Codable, Sendable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var confidence: Float?
    }

    // MARK: - Legacy field access

    // These delegate to `fingerprint` so the handful of call sites that only
    // ever *read* these for logging (`TranscriptionViewModel`,
    // `TranscriptionRecovery`) didn't need to change shape along with this type.
    var engineRaw: String { fingerprint.engineRaw }
    var languageRaw: String { fingerprint.languageRaw }
    var compacted: Bool { fingerprint.compacted }
    var providerID: String? { fingerprint.providerID }

    /// Whether this checkpoint's pipeline identity matches the run being
    /// attempted, up to the exact chunk plan — which isn't known until
    /// chunking runs; see `ChunkedTranscriptionRunner`'s separate
    /// `chunkPlanDigest` check.
    func matches(_ current: TranscriptionPipelineFingerprint) -> Bool {
        fingerprint == current
    }

    /// Structural sanity of the persisted numbers themselves, independent of
    /// whether `fingerprint` matches anything: `completedChunks` within
    /// bounds, and every span finite, non-negative, and within the
    /// *original* recording's duration (with a small slack for
    /// chunk-boundary rounding). Spans actually live on the engine-input
    /// timeline, which is shorter than the original when VAD-compaction
    /// removed silence — so this bound is deliberately loose rather than
    /// exact; it exists to catch gross corruption (a timestamp turned
    /// negative or wildly larger than the whole recording), not to fully
    /// re-derive the compacted timeline just to validate a checkpoint. A
    /// checkpoint that fails this must never seed a resume or reach fusion —
    /// a flipped byte inside an otherwise-valid envelope, or a hand-edited
    /// store, could otherwise produce spans nothing downstream expects.
    var isStructurallyValid: Bool {
        guard totalChunks >= 0, (0...totalChunks).contains(completedChunks) else { return false }
        guard fingerprint.sourceDuration.isFinite, fingerprint.sourceDuration >= 0 else { return false }
        // Generous: this exists to catch gross corruption (a timestamp turned
        // negative or absurdly large), not to enforce perfect chunk-boundary
        // ordering of spans that may legitimately arrive slightly reordered
        // within a chunk.
        let slack: TimeInterval = 30
        let upperBound = fingerprint.sourceDuration + slack
        var maxStartSoFar: TimeInterval = -slack
        for span in spans {
            guard span.start.isFinite, span.end.isFinite else { return false }
            guard span.start >= 0, span.end >= span.start else { return false }
            guard span.start <= upperBound, span.end <= upperBound else { return false }
            guard span.start >= maxStartSoFar - slack else { return false }
            maxStartSoFar = max(maxStartSoFar, span.start)
        }
        return true
    }
}

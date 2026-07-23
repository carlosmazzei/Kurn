//
//  TextEmbedding.swift
//  Kurn
//
//  Protocol seam over an on-device text embedder. Kept abstract (like the
//  transcription pipeline stages) so the concrete engine — Apple's
//  `NLContextualEmbedding` today — can be swapped without touching the index and
//  search services that depend on it.
//

import Foundation

/// Produces unit-normalized embedding vectors for passages of text, fully
/// on-device. Implementations are `Sendable` so indexing can run off the main
/// actor. Every vector an implementation returns must have length `dimension`
/// and be L2-normalized, so downstream cosine similarity is a plain dot product.
protocol TextEmbedding: Sendable {
    /// Stable id + version of the underlying model, persisted on each
    /// `SemanticChunk` so a backfill can detect and re-index stale vectors.
    /// Every vector length is captured per-chunk, so the dimension isn't part of
    /// this contract.
    var modelIdentifier: String { get }
    /// Embed each input string into a normalized vector, preserving order.
    /// Throws `AppError.embeddingUnavailable` when the on-device model can't be
    /// loaded (e.g. the OS asset isn't installed and can't be fetched).
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension TextEmbedding {
    /// Convenience for a single string.
    func embed(_ text: String) async throws -> [Float] {
        try await embed([text]).first ?? []
    }
}

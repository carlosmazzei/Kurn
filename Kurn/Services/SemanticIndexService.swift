//
//  SemanticIndexService.swift
//  Kurn
//
//  Turns a meeting's transcript passages into embedding vectors, off the main
//  actor. Pure value-in / value-out (like `SummaryService`): it never touches
//  SwiftData — the caller (a `@MainActor` coordinator) reads the transcript to
//  build chunks and persists the resulting `SemanticChunk`s. Keeping the model
//  work here means the encrypted store is only ever mutated on the main actor.
//

import Foundation

struct SemanticIndexService {
    private let embedder: TextEmbedding

    init(embedder: TextEmbedding = NLTextEmbedder()) {
        self.embedder = embedder
    }

    /// Model identifier stamped onto produced vectors, so a backfill can spot
    /// chunks embedded by an older model and re-index them.
    var modelIdentifier: String { embedder.modelIdentifier }

    /// A chunk paired with its embedding vector.
    struct EmbeddedChunk: Sendable {
        var chunk: TranscriptChunk
        var vector: [Float]
    }

    /// Embed every chunk, dropping any that produced an empty vector (e.g. a
    /// passage the embedder couldn't tokenize). Order is preserved.
    func embed(_ chunks: [TranscriptChunk]) async throws -> [EmbeddedChunk] {
        guard !chunks.isEmpty else { return [] }
        try Task.checkCancellation()

        let vectors = try await embedder.embed(chunks.map(\.text))
        var embedded: [EmbeddedChunk] = []
        embedded.reserveCapacity(chunks.count)
        for (chunk, vector) in zip(chunks, vectors) where !vector.isEmpty {
            embedded.append(EmbeddedChunk(chunk: chunk, vector: vector))
        }
        AppLog.transcription.atInfo.info("semanticIndex: embedded \(embedded.count, privacy: .public)/\(chunks.count, privacy: .public) chunks")
        return embedded
    }
}

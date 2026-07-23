//
//  EmbeddingModelStore.swift
//  Kurn
//
//  Process-wide loader/cache for Apple's on-device `NLContextualEmbedding`
//  model, mirroring `FluidAudioModelStore`: the model is loaded exactly once and
//  reused across indexing and query, and concurrent callers coalesce onto a
//  single in-flight load instead of each loading a copy.
//
//  The non-`Sendable` `NLContextualEmbedding` never leaves this actor — callers
//  hand in text and get back plain `[Float]` vectors, so the model stays
//  isolated. A single multilingual latin-script model is used for every passage
//  so all vectors share one embedding space and dimension; the app's shipped
//  languages (en, pt-BR, es, fr, it, de) are all latin-script.
//

import Foundation
import NaturalLanguage

actor EmbeddingModelStore {
    static let shared = EmbeddingModelStore()

    /// Persisted on every `SemanticChunk`; bump the version suffix when the
    /// model or pooling changes so the backfill re-indexes existing chunks.
    static let modelIdentifier = "nl-contextual-latin-v1"

    // `NLContextualEmbedding` is not `Sendable`, so it must never leave this
    // actor. It is created, loaded, and used entirely under actor isolation; the
    // in-flight `loadTask` returns `Void` (Sendable) rather than the model.
    private var model: NLContextualEmbedding?
    /// In-flight load so racing callers await one load instead of several.
    private var loadTask: Task<Void, Error>?

    private init() {}

    /// Embed each passage into a unit-normalized mean-pooled vector, preserving
    /// order. Empty/whitespace input yields an empty vector (skipped upstream).
    func embed(_ texts: [String]) async throws -> [[Float]] {
        let model = try await loadedModel()
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try Self.vector(for: text, model: model))
        }
        return results
    }

    /// The loaded model, fetching the OS asset on first use if needed. Failures
    /// aren't cached — the next call retries.
    private func loadedModel() async throws -> NLContextualEmbedding {
        if let model { return model }
        if let loadTask {
            try await loadTask.value
            if let model { return model }
        }

        // `Task {}` created here inherits this actor's isolation, so the
        // non-Sendable model never crosses an isolation boundary.
        let task = Task { try await self.performLoad() }
        loadTask = task
        defer { loadTask = nil }
        do {
            try await task.value
        } catch {
            AppLog.transcription.atError.error("embedding: model load failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let model else {
            throw AppError.embeddingUnavailable(
                NSLocalizedString("error.embedding_no_model", comment: "No contextual embedding model")
            )
        }
        return model
    }

    /// Create, fetch assets for, and load the model, storing it on the actor.
    private func performLoad() async throws {
        guard let embedding = NLContextualEmbedding(script: .latin) else {
            throw AppError.embeddingUnavailable(
                NSLocalizedString("error.embedding_no_model", comment: "No contextual embedding model")
            )
        }
        if !embedding.hasAvailableAssets {
            try await requestAssets(for: embedding)
        }
        do {
            try embedding.load()
        } catch {
            throw AppError.embeddingUnavailable(error.localizedDescription)
        }
        model = embedding
        AppLog.transcription.atNotice.notice("embedding: NLContextualEmbedding loaded (latin, dim=\(embedding.dimension, privacy: .public))")
    }

    /// Ask the OS to download the embedding asset. The model contains no user
    /// data, so no `ResourceGuard`/consent gating is needed — unlike FluidAudio.
    /// Actor-isolated so `embedding` (non-Sendable) never crosses out.
    private func requestAssets(for embedding: NLContextualEmbedding) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            embedding.requestAssets { result, error in
                if case .available = result {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppError.embeddingUnavailable(
                        error?.localizedDescription
                            ?? NSLocalizedString("error.embedding_no_assets", comment: "Embedding assets unavailable")
                    ))
                }
            }
        }
    }

    /// Mean-pool the token vectors of `text` and L2-normalize, so cosine
    /// similarity downstream is a plain dot product.
    private static func vector(for text: String, model: NLContextualEmbedding) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let result: NLContextualEmbeddingResult
        do {
            result = try model.embeddingResult(for: trimmed, language: nil)
        } catch {
            throw AppError.embeddingUnavailable(error.localizedDescription)
        }

        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            let n = min(vector.count, sum.count)
            for index in 0..<n { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { return [] }

        var mean = sum.map { Float($0 / Double(count)) }
        normalize(&mean)
        return mean
    }

    private static func normalize(_ vector: inout [Float]) {
        var norm: Float = 0
        for value in vector { norm += value * value }
        norm = norm.squareRoot()
        guard norm > 0 else { return }
        for index in vector.indices { vector[index] /= norm }
    }
}

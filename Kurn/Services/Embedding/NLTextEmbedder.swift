//
//  NLTextEmbedder.swift
//  Kurn
//
//  `TextEmbedding` backed by Apple's on-device `NLContextualEmbedding` (via
//  `EmbeddingModelStore`). Zero external dependency: the `NaturalLanguage`
//  framework and its embedding asset ship with the OS, so nothing here downloads
//  a third-party model. A thin `Sendable` forwarder — all state lives in the
//  shared actor.
//

import Foundation

struct NLTextEmbedder: TextEmbedding {
    var modelIdentifier: String { EmbeddingModelStore.modelIdentifier }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await EmbeddingModelStore.shared.embed(texts)
    }
}

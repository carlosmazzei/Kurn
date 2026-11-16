import Foundation
import KurnCore

/// Vectors are typed derivatives of one authorized revision, not transcript
/// passages. They live only for this request and never reach a provider.
struct KnowledgeIndexedDocument: Equatable, Sendable {
    let document: KnowledgeSearchDocument
    let modelIdentifier: String
    let vector: [Float]
}

struct KnowledgeSearchService: Sendable {
    private let embedder: any TextEmbedding

    init(embedder: any TextEmbedding = InstalledTextEmbedder()) { self.embedder = embedder }

    func search(query: String, read: KnowledgeBrowserRead, useSemantic: Bool,
                authorizeEmbedding: @Sendable () async throws -> Bool = { false }) async throws -> [KnowledgeSearchDocument] {
        let index = try KnowledgeSearchIndex(pages: read.pages, meetingIDs: read.meetingIDs)
        // Validate before any model work, including empty/oversized queries.
        let lexical = try index.search(query: query)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, useSemantic, read.allowsEmbedding,
              !index.documents.isEmpty, index.documents.count <= 128,
              index.documents.reduce(0, { $0 + $1.text.utf8.count }) <= 131_072 else { return lexical }
        try Task.checkCancellation()
        let identifier = embedder.modelIdentifier
        let vectors: [[Float]]
        do {
            vectors = try await withResourceReservation(.knowledgeGeneration(onDevice: true)) {
                try Task.checkCancellation()
                guard try await authorizeEmbedding() else { return [] }
                try Task.checkCancellation()
                return try await embedder.embed([query] + index.documents.map(\.text))
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return lexical } // Missing OS assets keep lexical search usable.
        try Task.checkCancellation()
        guard identifier == embedder.modelIdentifier, vectors.count == index.documents.count + 1,
              let queryVector = vectors.first, !queryVector.isEmpty, queryVector.allSatisfy(\.isFinite) else { return lexical }
        let indexed = zip(index.documents, vectors.dropFirst()).map {
            KnowledgeIndexedDocument(document: $0.0, modelIdentifier: identifier, vector: $0.1)
        }
        let dense = indexed.indices.compactMap { position -> (Int, Double)? in
            let candidate = indexed[position]
            guard candidate.modelIdentifier == identifier, candidate.vector.count == queryVector.count,
                  candidate.vector.allSatisfy(\.isFinite) else { return nil }
            let score = zip(candidate.vector, queryVector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            guard score.isFinite, score > 0 else { return nil }
            return (position, score)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map(\.0)
        return try index.search(query: query, denseOrder: dense)
    }

    static func validates(_ hits: [KnowledgeSearchDocument], in read: KnowledgeBrowserRead) async throws -> Bool {
        guard hits.count <= 100, Set(hits.map(\.id)).count == hits.count else { return false }
        let documents = try KnowledgeSearchIndex(pages: read.pages, meetingIDs: read.meetingIDs).documents
        let allowed = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return hits.allSatisfy { allowed[$0.id] == $0 }
    }

}

/// Knowledge search must work offline without triggering an OS asset request.
private struct InstalledTextEmbedder: TextEmbedding {
    var modelIdentifier: String { EmbeddingModelStore.modelIdentifier }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await EmbeddingModelStore.shared.embedUsingAvailableAssets(texts)
    }
}

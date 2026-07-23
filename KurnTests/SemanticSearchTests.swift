//
//  SemanticSearchTests.swift
//  KurnTests
//
//  Covers the vector plumbing behind semantic search: `Float32 <-> Data`
//  round-tripping and normalization, and cosine ranking in
//  `SemanticSearchService` (via a stub embedder so no OS model is loaded).
//

import Foundation
import Testing
@testable import Kurn

/// Deterministic embedder for tests: returns whatever vector was registered for
/// a given string, already normalized by the caller.
private struct StubEmbedder: TextEmbedding {
    let modelIdentifier = "stub-v1"
    let table: [String: [Float]]
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { table[$0] ?? [] }
    }
}

struct SemanticSearchTests {

    // MARK: - VectorData

    @Test func vectorRoundTripsThroughData() {
        let vector: [Float] = [0.5, -1.25, 3.0, 0.0, 42.42]
        let decoded = VectorData.decode(VectorData.encode(vector))
        #expect(decoded.count == vector.count)
        for (a, b) in zip(vector, decoded) {
            #expect(abs(a - b) < 0.0001)
        }
    }

    @Test func decodeRejectsMisalignedBytes() {
        // 5 bytes is not a whole number of Float32s.
        #expect(VectorData.decode(Data([1, 2, 3, 4, 5])).isEmpty)
    }

    // MARK: - Ranking

    private func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    private func candidate(_ id: UUID, meeting: UUID, text: String, vector: [Float]) -> SemanticSearchService.Candidate {
        SemanticSearchService.Candidate(
            chunkID: id, meetingID: meeting, recordingID: UUID(),
            text: text, start: 0, end: 1, speakerLabel: "Speaker 1", vector: vector
        )
    }

    @Test func rankingOrdersByCosineSimilarity() async throws {
        let query = normalize([1, 0, 0])
        let near = normalize([0.9, 0.1, 0])
        let far = normalize([0, 1, 0])
        let m1 = UUID()
        let m2 = UUID()

        let service = SemanticSearchService(embedder: StubEmbedder(table: ["find topic": query]))
        let hits = try await service.search(
            query: "find topic",
            in: [
                candidate(UUID(), meeting: m2, text: "far", vector: far),
                candidate(UUID(), meeting: m1, text: "near", vector: near)
            ],
            minScore: 0
        )
        #expect(hits.count == 2)
        #expect(hits.first?.text == "near")
        #expect((hits.first?.score ?? 0) > (hits.last?.score ?? 1))
    }

    @Test func minScoreFiltersWeakMatches() async throws {
        let query = normalize([1, 0, 0])
        let orthogonal = normalize([0, 1, 0]) // cosine 0
        let service = SemanticSearchService(embedder: StubEmbedder(table: ["q": query]))
        let hits = try await service.search(
            query: "q",
            in: [candidate(UUID(), meeting: UUID(), text: "x", vector: orthogonal)],
            minScore: 0.5
        )
        #expect(hits.isEmpty)
    }

    @Test func mismatchedDimensionCandidatesAreSkipped() async throws {
        let query = normalize([1, 0, 0])
        let service = SemanticSearchService(embedder: StubEmbedder(table: ["q": query]))
        let hits = try await service.search(
            query: "q",
            in: [candidate(UUID(), meeting: UUID(), text: "wrongdim", vector: [1, 0])],
            minScore: 0
        )
        #expect(hits.isEmpty)
    }

    @Test func bestPerMeetingKeepsHighestRankedPerMeeting() {
        let meeting = UUID()
        let hits = [
            SemanticSearchService.Hit(chunkID: UUID(), meetingID: meeting, recordingID: UUID(),
                                      text: "top", start: 0, end: 1, speakerLabel: "S1", score: 0.9),
            SemanticSearchService.Hit(chunkID: UUID(), meetingID: meeting, recordingID: UUID(),
                                      text: "lower", start: 0, end: 1, speakerLabel: "S1", score: 0.5)
        ]
        let best = SemanticSearchService.bestPerMeeting(hits)
        #expect(best.count == 1)
        #expect(best.first?.text == "top")
    }

    @Test func diversifyCapsHitsPerMeetingPreservingRank() {
        let m1 = UUID()
        let m2 = UUID()
        func h(_ text: String, meeting: UUID, score: Float) -> SemanticSearchService.Hit {
            SemanticSearchService.Hit(chunkID: UUID(), meetingID: meeting, recordingID: UUID(),
                                      text: text, start: 0, end: 1, speakerLabel: "S1", score: score)
        }
        // Ranked order: a1, a2, a3 (m1), b1 (m2).
        let hits = [
            h("a1", meeting: m1, score: 0.9), h("a2", meeting: m1, score: 0.8),
            h("a3", meeting: m1, score: 0.7), h("b1", meeting: m2, score: 0.6)
        ]
        let diversified = SemanticSearchService.diversify(hits, maxPerMeeting: 2)
        #expect(diversified.map(\.text) == ["a1", "a2", "b1"])
        // maxPerMeeting: 1 matches bestPerMeeting.
        #expect(SemanticSearchService.diversify(hits, maxPerMeeting: 1).map(\.text) == ["a1", "b1"])
        #expect(SemanticSearchService.diversify(hits, maxPerMeeting: 0).isEmpty)
    }

    @Test func emptyQueryReturnsNoHits() async throws {
        let service = SemanticSearchService(embedder: StubEmbedder(table: [:]))
        let hits = try await service.search(query: "   ", in: [], minScore: 0)
        #expect(hits.isEmpty)
    }

    // MARK: - Hybrid retrieval

    @Test func tokenizeLowercasesAndDropsSingleChars() {
        let tokens = SemanticSearchService.tokenize("Preço, MCP e a decisão!")
        #expect(tokens.contains("preço"))
        #expect(tokens.contains("mcp"))
        #expect(tokens.contains("decisão"))
        #expect(!tokens.contains("e")) // single char dropped
        #expect(!tokens.contains("a"))
    }

    @Test func bm25RanksDocContainingQueryTermFirst() {
        let match = candidate(UUID(), meeting: UUID(), text: "we agreed on the pricing model", vector: [1, 0])
        let noMatch = candidate(UUID(), meeting: UUID(), text: "lunch logistics and parking", vector: [0, 1])
        let order = SemanticSearchService.bm25Order(query: "pricing", candidates: [noMatch, match])
        #expect(order.first == 1) // index of the matching candidate
        #expect(!order.contains(0)) // non-matching doc scores zero and is dropped
    }

    @Test func rrfRewardsItemsRankedHighInBothLists() {
        let fused = SemanticSearchService.reciprocalRankFusion([[5, 1, 3], [1, 9, 5]])
        // 1 is high in both, so it should win.
        #expect(fused.first?.index == 1)
    }

    @Test func hybridDegradesToLexicalWhenEmbedderEmpty() async throws {
        // StubEmbedder returns [] for anything not in its table → dense side empty,
        // so ranking must fall back to lexical keyword matching.
        let service = SemanticSearchService(embedder: StubEmbedder(table: [:]))
        let match = candidate(UUID(), meeting: UUID(), text: "the budget was approved", vector: [1, 0])
        let other = candidate(UUID(), meeting: UUID(), text: "unrelated chit chat", vector: [0, 1])
        let hits = try await service.hybridSearch(query: "budget", in: [other, match], poolSize: 10)
        #expect(hits.first?.text == "the budget was approved")
    }
}

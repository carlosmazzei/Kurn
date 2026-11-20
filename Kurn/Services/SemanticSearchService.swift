//
//  SemanticSearchService.swift
//  Kurn
//
//  Ranks pre-embedded transcript passages against a query by cosine similarity,
//  off the main actor. `SemanticChunk`s are read on the main actor and handed in
//  as plain `Candidate` value snapshots, so this service never touches SwiftData
//  and the ranking (a batched `vDSP` dot product, since vectors are normalized)
//  stays a pure computation. Backs both the global meetings-list search and the
//  chat retrieval (RAG) step.
//

import Accelerate
import Foundation
import KurnCore

struct SemanticSearchService {
    private let embedder: TextEmbedding

    init(embedder: TextEmbedding = NLTextEmbedder()) {
        self.embedder = embedder
    }

    /// A main-actor snapshot of one `SemanticChunk`, safe to rank off-main.
    struct Candidate: Codable, Sendable {
        var chunkID: UUID
        var meetingID: UUID
        var recordingID: UUID
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var speakerLabel: String
        var vector: [Float]
        /// Owning meeting's display title, read on the main actor when the
        /// snapshot is built. Lets the library-wide chat attribute a passage to a
        /// meeting and compare across meetings — the raw chunk carries none.
        var meetingTitle: String = ""
        /// Owning meeting's creation date, for the same attribution.
        var meetingDate: Date = .distantPast
    }

    /// A ranked passage, carrying enough to render a snippet and deep-link to
    /// the moment in the transcript.
    struct Hit: Sendable, Identifiable {
        var id: UUID { chunkID }
        var chunkID: UUID
        var meetingID: UUID
        var recordingID: UUID
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var speakerLabel: String
        var score: Float
        /// Owning meeting's display title, carried through from the `Candidate`
        /// so citations and the library prompt can name their source meeting.
        var meetingTitle: String = ""
        /// Owning meeting's creation date.
        var meetingDate: Date = .distantPast
    }

    /// Embed `query` once and return the top `limit` candidates whose cosine
    /// similarity clears `minScore`, best first. Candidates whose vector length
    /// doesn't match the query (a different/older embedder) are skipped rather
    /// than mis-scored.
    func search(
        query: String,
        in candidates: [Candidate],
        limit: Int = 20,
        minScore: Float = 0.15
    ) async throws -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return [] }

        let queryVector = try await embedder.embed(trimmed)
        guard !queryVector.isEmpty else { return [] }

        var hits: [Hit] = []
        hits.reserveCapacity(candidates.count)
        for candidate in candidates where candidate.vector.count == queryVector.count {
            let score = vDSP.dot(queryVector, candidate.vector)
            guard score >= minScore else { continue }
            hits.append(makeHit(from: candidate, score: score))
        }

        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    // MARK: - Hybrid retrieval (dense + lexical, RRF-fused)

    /// Retrieve a candidate pool by fusing dense (semantic) and lexical
    /// (keyword) rankings with Reciprocal Rank Fusion. `denseText` is embedded
    /// for the semantic side — pass a rewritten/expanded query or a hypothetical
    /// answer; `query` drives the lexical side. Returns up to `poolSize` hits,
    /// best first, scored by RRF. Used for chat retrieval; the meetings list
    /// keeps the plain cosine `search` above. If the embedder is unavailable it
    /// degrades to lexical-only.
    func hybridSearch(
        query: String,
        denseText: String? = nil,
        in candidates: [Candidate],
        poolSize: Int = 30
    ) async throws -> [Hit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidates.isEmpty else { return [] }

        let denseCandidate = denseText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let denseSource = denseCandidate.isEmpty ? trimmedQuery : denseCandidate
        var denseOrder: [Int] = []
        if !denseSource.isEmpty,
           let queryVector = try? await embedder.embed(denseSource), !queryVector.isEmpty {
            denseOrder = candidates.indices
                .filter { candidates[$0].vector.count == queryVector.count }
                .map { (index: $0, score: vDSP.dot(queryVector, candidates[$0].vector)) }
                .sorted { $0.score > $1.score }
                .map(\.index)
        }

        let lexicalOrder = Self.bm25Order(query: trimmedQuery, candidates: candidates)
        // RRF degrades to whichever side is non-empty.
        let fused = Self.reciprocalRankFusion([denseOrder, lexicalOrder])
        return fused.prefix(poolSize).map { entry in
            makeHit(from: candidates[entry.index], score: Float(entry.score))
        }
    }

    private func makeHit(from candidate: Candidate, score: Float) -> Hit {
        Hit(
            chunkID: candidate.chunkID,
            meetingID: candidate.meetingID,
            recordingID: candidate.recordingID,
            text: candidate.text,
            start: candidate.start,
            end: candidate.end,
            speakerLabel: candidate.speakerLabel,
            score: score,
            meetingTitle: candidate.meetingTitle,
            meetingDate: candidate.meetingDate
        )
    }

    /// Candidate indices ranked by BM25 (k1=1.5, b=0.75) over the pool, dropping
    /// zero-score docs. Pure and deterministic.
    static func bm25Order(query: String, candidates: [Candidate]) -> [Int] {
        HybridSearchRanking.bm25Order(query: query, texts: candidates.map(\.text))
    }

    static func tokenize(_ text: String) -> [String] { HybridSearchRanking.tokenize(text) }

    static func reciprocalRankFusion(_ rankings: [[Int]], k: Int = 60) -> [(index: Int, score: Double)] {
        HybridSearchRanking.reciprocalRankFusion(rankings, k: k)
    }

    /// Keep at most `maxPerMeeting` hits from any one meeting, preserving global rank order.
    static func diversify(_ hits: [Hit], maxPerMeeting: Int) -> [Hit] {
        guard maxPerMeeting > 0 else { return [] }
        var counts: [UUID: Int] = [:]
        var result: [Hit] = []
        for hit in hits {
            let count = counts[hit.meetingID, default: 0]
            guard count < maxPerMeeting else { continue }
            counts[hit.meetingID] = count + 1
            result.append(hit)
        }
        return result
    }

    /// Best hit per meeting (highest score), preserving global rank order —
    /// used by the meetings list, which shows one row per meeting.
    static func bestPerMeeting(_ hits: [Hit]) -> [Hit] {
        diversify(hits, maxPerMeeting: 1)
    }
}

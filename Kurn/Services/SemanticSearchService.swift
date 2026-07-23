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

struct SemanticSearchService {
    private let embedder: TextEmbedding

    init(embedder: TextEmbedding = NLTextEmbedder()) {
        self.embedder = embedder
    }

    /// A main-actor snapshot of one `SemanticChunk`, safe to rank off-main.
    struct Candidate: Sendable {
        var chunkID: UUID
        var meetingID: UUID
        var recordingID: UUID
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var speakerLabel: String
        var vector: [Float]
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
            hits.append(Hit(
                chunkID: candidate.chunkID,
                meetingID: candidate.meetingID,
                recordingID: candidate.recordingID,
                text: candidate.text,
                start: candidate.start,
                end: candidate.end,
                speakerLabel: candidate.speakerLabel,
                score: score
            ))
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
            score: score
        )
    }

    /// Candidate indices ranked by BM25 (k1=1.5, b=0.75) over the pool, dropping
    /// zero-score docs. Pure and deterministic.
    static func bm25Order(query: String, candidates: [Candidate]) -> [Int] {
        let queryTerms = Set(tokenize(query))
        guard !queryTerms.isEmpty else { return [] }

        let docs = candidates.map { tokenize($0.text) }
        let count = docs.count
        let avgdl = Double(docs.reduce(0) { $0 + $1.count }) / Double(max(count, 1))

        var docFreq: [String: Int] = [:]
        for doc in docs {
            let present = Set(doc)
            for term in queryTerms where present.contains(term) { docFreq[term, default: 0] += 1 }
        }

        let k1 = 1.5, bParam = 0.75
        var scored: [(index: Int, score: Double)] = []
        for (index, doc) in docs.enumerated() where !doc.isEmpty {
            var termFreq: [String: Int] = [:]
            for term in doc { termFreq[term, default: 0] += 1 }
            let docLen = Double(doc.count)
            var score = 0.0
            for term in queryTerms {
                guard let freq = termFreq[term], freq > 0, let df = docFreq[term], df > 0 else { continue }
                let idf = log(1 + (Double(count) - Double(df) + 0.5) / (Double(df) + 0.5))
                let tfPart = (Double(freq) * (k1 + 1)) / (Double(freq) + k1 * (1 - bParam + bParam * docLen / avgdl))
                score += idf * tfPart
            }
            if score > 0 { scored.append((index, score)) }
        }
        return scored.sorted { $0.score > $1.score }.map(\.index)
    }

    /// Split into lowercased alphanumeric tokens (Unicode-aware, so accented
    /// Portuguese words survive), dropping single characters.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// Reciprocal Rank Fusion of several rank lists (each a list of candidate
    /// indices, best first). Higher fused score = better.
    static func reciprocalRankFusion(_ rankings: [[Int]], k: Int = 60) -> [(index: Int, score: Double)] {
        var score: [Int: Double] = [:]
        for ranking in rankings {
            for (rank, index) in ranking.enumerated() {
                score[index, default: 0] += 1.0 / Double(k + rank + 1)
            }
        }
        return score.map { (index: $0.key, score: $0.value) }.sorted { $0.score > $1.score }
    }

    /// Best hit per meeting (highest score), preserving global rank order —
    /// used by the meetings list, which shows one row per meeting.
    static func bestPerMeeting(_ hits: [Hit]) -> [Hit] {
        var seen = Set<UUID>()
        var result: [Hit] = []
        for hit in hits where seen.insert(hit.meetingID).inserted {
            result.append(hit)
        }
        return result
    }
}

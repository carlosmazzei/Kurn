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

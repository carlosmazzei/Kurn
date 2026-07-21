//
//  SemanticChunk.swift
//  Kurn
//
//  One embedded passage of a meeting's transcript: a short window of text with
//  its absolute meeting timestamps, the speaker, and the on-device embedding
//  vector used for semantic search and chat retrieval (RAG).
//
//  The passage text and its `vectorData` live inside the SwiftData store, so
//  they are encrypted at rest by `ModelStoreProtection` (`.completeUnlessOpen`)
//  exactly like transcripts and summaries. Vectors are kept in-store as `Data`
//  (never a loose file/cache) precisely so no unprotected sidecar is introduced.
//

import Foundation
import SwiftData

@Model
final class SemanticChunk {
    @Attribute(.unique) var id: UUID
    /// Owning meeting. The inverse `Meeting.semanticChunks` is `.cascade`, so
    /// deleting a meeting removes its chunks with the rest of its data.
    var meeting: Meeting?
    /// Recording this passage came from, so a hit can point back at the source
    /// recording without a relationship (chunks are rebuilt, not navigated).
    var recordingID: UUID
    /// The passage text that was embedded and is shown as the search snippet.
    var text: String
    /// Absolute meeting-relative start/end (recording offset already applied),
    /// so a hit can deep-link to the moment in the transcript.
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// Dominant speaker label for the passage (e.g. "Speaker 1").
    var speakerLabel: String
    /// Unit-normalized embedding as little-endian `Float32` bytes; see
    /// `VectorData`. Normalized so cosine similarity is a plain dot product.
    var vectorData: Data
    /// Vector length, stored so a query can skip mismatched-dimension rows
    /// without decoding them.
    var dimension: Int
    /// Embedder id + version that produced `vectorData`. A backfill pass
    /// re-indexes chunks whose identifier no longer matches the current embedder.
    var modelIdentifier: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        recordingID: UUID,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerLabel: String,
        vector: [Float],
        modelIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meeting = meeting
        self.recordingID = recordingID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerLabel = speakerLabel
        self.vectorData = VectorData.encode(vector)
        self.dimension = vector.count
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
    }

    /// The embedding vector, decoded from `vectorData`.
    var vector: [Float] {
        get { VectorData.decode(vectorData) }
        set {
            vectorData = VectorData.encode(newValue)
            dimension = newValue.count
        }
    }

    /// A `Sendable` value snapshot for off-main ranking. Built on the main actor
    /// (it reads the model), then handed to `SemanticSearchService`.
    var searchCandidate: SemanticSearchService.Candidate {
        SemanticSearchService.Candidate(
            chunkID: id,
            meetingID: meeting?.id ?? UUID(),
            recordingID: recordingID,
            text: text,
            start: startTime,
            end: endTime,
            speakerLabel: speakerLabel,
            vector: vector
        )
    }
}

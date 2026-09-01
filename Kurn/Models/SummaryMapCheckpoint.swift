//
//  SummaryMapCheckpoint.swift
//  Kurn
//
//  Durable progress of a staged (map-reduce) summary run, persisted on
//  `Meeting` (as JSON `Data`, same pattern as `Recording.transcriptionCheckpoint`).
//  A meeting long enough to need the staged path condenses each block into
//  intermediate notes before the final reduce pass; without this, killing the
//  app or losing the network mid-run meant redoing — and for a cloud provider,
//  re-paying for — every block from the start (H4).
//
//  Summary and Wiki generation share this one checkpoint per meeting rather
//  than each keeping their own: `WikiService.generate` delegates to
//  `SummaryService.generate` with the same `notesTemplate` the summary map
//  stage already uses, so for a given meeting the map stage produces
//  byte-identical notes regardless of which artifact triggered it. A summary
//  run and a wiki run racing on the same meeting can therefore share (or
//  briefly overwrite) each other's progress with no correctness risk — the
//  worst case is redoing one already-completed block, never spliced or
//  incorrect notes. `GeneratedDocument` generation is deliberately not wired
//  to this: it can combine multiple meetings' text into one map-reduce run,
//  which has no single `Meeting` to persist a checkpoint on.
//

import Foundation

struct SummaryMapCheckpoint: Codable, Sendable {
    /// SHA-256 of the exact transcript text fed to the map stage. A
    /// re-transcription (different content) must never resume into notes
    /// condensed from the old text.
    var contentDigest: String
    /// The summary provider's id, so a checkpoint written by one vendor is
    /// never resumed by another — splicing GPT-authored notes with
    /// Groq-authored ones would be the same quality-mixing bug H4 already
    /// closed for transcription checkpoints.
    var providerID: String
    /// Exact model string, for the same reason: a different model from the
    /// same vendor is still a different quality tier.
    var model: String
    /// Block count of the plan these notes belong to. Text splitting is a
    /// pure function of (content, provider-class-dependent block size), so —
    /// unlike audio chunking — content + provider + model + count is already
    /// an exact identity; there is no separate non-deterministic cut-point
    /// axis here to fingerprint.
    var totalBlocks: Int
    /// Condensed notes for blocks `0..<completedNotes.count`, in order.
    var completedNotes: [String]

    /// Whether this checkpoint may seed a resume of the run described by the
    /// given identity.
    func matches(contentDigest: String, providerID: String, model: String, totalBlocks: Int) -> Bool {
        self.contentDigest == contentDigest
            && self.providerID == providerID
            && self.model == model
            && self.totalBlocks == totalBlocks
    }

    /// Structural sanity independent of whether the identity matches
    /// anything: `completedNotes` can never describe more blocks than the
    /// plan has. A checkpoint that fails this must never seed a resume.
    var isStructurallyValid: Bool {
        totalBlocks >= 0 && completedNotes.count <= totalBlocks
    }
}

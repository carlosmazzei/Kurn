//
//  SummaryMapRunner.swift
//  Kurn
//
//  Shared loop behind the map stage of `SummaryService`'s staged (map-reduce)
//  summarization: iterates the block plan, skips already-condensed blocks when
//  resuming, honors cooperative cancellation between blocks, and reports
//  durable progress after every block — the summary-generation analogue of
//  `ChunkedTranscriptionRunner` (H4). Kept independent of `LLMProvider` (the
//  actual condensing call is injected) so it's testable without a real or
//  mocked network call.
//

import Foundation

enum SummaryMapRunner {

    /// Run the map stage, optionally resuming from prior progress.
    /// - Parameters:
    ///   - blocks: the transcript split into map-stage blocks.
    ///   - contentDigest: identity of the transcript text being condensed.
    ///   - providerID: identity of the summary provider in use.
    ///   - model: identity of the exact model in use.
    ///   - resume: a checkpoint from an interrupted run; ignored unless its
    ///     identity matches this run's exactly.
    ///   - condenseBlock: condenses one block (given its zero-based index)
    ///     into its notes.
    ///   - onStageCompleted: durable-progress sink invoked after each block
    ///     and awaited before the next one starts (same H4 contract as
    ///     `ChunkedTranscriptionRunner.run`'s `onChunkCompleted`): a
    ///     checkpoint is not durable until this returns, so a thrown error
    ///     stops the run at the last durably-committed block instead of
    ///     risking the next block's cost on top of unsaved progress.
    static func run(
        blocks: [String],
        contentDigest: String,
        providerID: String,
        model: String,
        resume: SummaryMapCheckpoint?,
        condenseBlock: @Sendable (String, Int) async throws -> String,
        onStageCompleted: (@Sendable (SummaryMapCheckpoint) async throws -> Void)? = nil
    ) async throws -> [String] {
        var notes: [String]
        if let resume, resume.isStructurallyValid,
           resume.matches(contentDigest: contentDigest, providerID: providerID, model: model, totalBlocks: blocks.count) {
            notes = resume.completedNotes
            if !notes.isEmpty {
                AppLog.transcription.atNotice.notice("summary: map resuming at block \(notes.count + 1, privacy: .public)/\(blocks.count, privacy: .public)")
            }
        } else {
            if resume != nil {
                AppLog.transcription.atNotice.notice("summary: map checkpoint mismatch, starting over")
            }
            notes = []
        }

        for index in notes.count..<blocks.count {
            try Task.checkCancellation()
            let note = try await condenseBlock(blocks[index], index)
            notes.append(note)
            let checkpoint = SummaryMapCheckpoint(
                contentDigest: contentDigest,
                providerID: providerID,
                model: model,
                totalBlocks: blocks.count,
                completedNotes: notes
            )
            // Awaited, not fired-and-forgotten: the next block must not start
            // before this one's notes are durably committed (H4).
            try await onStageCompleted?(checkpoint)
        }

        return notes
    }
}

//
//  WikiService.swift
//  Kurn
//
//  Generates a meeting's condensed "wiki" article: dense, factual, timestamped
//  notes over the whole transcript. Pure value-in / value-out, off the main
//  actor, exactly like `SummaryService` (which it reuses).
//
//  Rather than re-implement chunking and the map-reduce staging, this delegates
//  to `SummaryService` with its internal `notesTemplate` — the same "capture
//  every decision, action item, number, name, with [mm:ss]" format the summary
//  map stage already produces — and renders the result to markdown. So a long
//  meeting is condensed in stages and a short one in a single pass, with the
//  same cancellation, retry, and rate-limit behaviour as summaries.
//

import Foundation

struct WikiService {
    private let summaryService = SummaryService()

    /// Build the condensed wiki markdown for a meeting's transcript. Uses the
    /// summary map-stage notes template for both stages, so the output is
    /// factual notes rather than a persona-styled summary.
    ///
    /// `resume`/`onMapStageCompleted` pass straight through to
    /// `SummaryService.generate` (H4): because the map stage always uses
    /// `notesTemplate` regardless of caller, a checkpoint written by a
    /// summary run over the same meeting content is just as valid a resume
    /// seed here, and vice versa — see `SummaryMapCheckpoint`'s header.
    func generate(
        transcriptText: String,
        meetingTitle: String,
        provider: AIProvider,
        model: String,
        resume: SummaryMapCheckpoint? = nil,
        onMapStageCompleted: (@Sendable (SummaryMapCheckpoint) async throws -> Void)? = nil
    ) async throws -> String {
        let result = try await summaryService.generate(
            transcriptText: transcriptText,
            meetingTitle: meetingTitle,
            provider: provider,
            model: model,
            template: SummaryService.notesTemplate,
            resume: resume,
            onMapStageCompleted: onMapStageCompleted
        )
        return SummaryService.markdownText(from: result.sections)
    }
}

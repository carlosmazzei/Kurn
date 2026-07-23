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
    func generate(
        transcriptText: String,
        meetingTitle: String,
        provider: AIProvider,
        model: String
    ) async throws -> String {
        let result = try await summaryService.generate(
            transcriptText: transcriptText,
            meetingTitle: meetingTitle,
            provider: provider,
            model: model,
            template: SummaryService.notesTemplate
        )
        return SummaryService.markdownText(from: result.sections)
    }
}

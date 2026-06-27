//
//  SummaryService.swift
//  Kurn
//
//  Builds the summary prompt from a meeting's transcripts and delegates to the
//  configured LLM provider. Pure value-in / value-out so it stays off SwiftData.
//

import Foundation

struct SummaryService {

    /// Generate a structured summary for already-assembled transcript text.
    /// - Parameters:
    ///   - transcriptText: speaker-labelled, timestamped transcript of the whole
    ///     meeting.
    ///   - meetingTitle: included for light context in the prompt.
    ///   - provider: which vendor to use (resolved to a key via ProviderFactory).
    ///   - template: shapes the persona/focus and the summary's sections.
    func generate(
        transcriptText: String,
        meetingTitle: String,
        provider: AIProvider,
        model: String,
        template: SummaryTemplate
    ) async throws -> SummaryResult {
        let trimmed = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.transcriptionFailed(
                NSLocalizedString("error.no_transcript", comment: "No transcript to summarize")
            )
        }

        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        let userPrompt = """
        Meeting title: \(meetingTitle)

        Transcript:
        \(trimmed)
        """

        return try await llm.summarize(
            systemPrompt: SummaryPrompt.system(for: template),
            userPrompt: userPrompt
        )
    }

    /// Assemble a single prompt-ready transcript string from per-recording
    /// segment lists. `[mm:ss] Speaker: text` lines, one per segment. Each group
    /// carries the recording's `offset` (seconds from the meeting start), so the
    /// timestamps read as one continuous, chronologically ordered timeline across
    /// multiple recordings rather than restarting at 0:00 per segment.
    static func assembleTranscriptText(
        from groups: [(offset: TimeInterval, segments: [TranscriptSegment])]
    ) -> String {
        var lines: [String] = []
        for group in groups {
            for segment in group.segments {
                let stamp = (segment.startTime + group.offset).clockDisplay
                lines.append("[\(stamp)] \(segment.speakerLabel): \(segment.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

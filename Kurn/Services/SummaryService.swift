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
    func generate(
        transcriptText: String,
        meetingTitle: String,
        provider: AIProvider,
        model: String
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
            systemPrompt: SummaryPrompt.system,
            userPrompt: userPrompt
        )
    }

    /// Assemble a single prompt-ready transcript string from per-recording
    /// segment lists. `[mm:ss] Speaker: text` lines, blank line between segments.
    static func assembleTranscriptText(
        from segmentGroups: [[TranscriptSegment]]
    ) -> String {
        var lines: [String] = []
        for segments in segmentGroups {
            for segment in segments {
                let stamp = segment.startTime.clockDisplay
                lines.append("[\(stamp)] \(segment.speakerLabel): \(segment.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

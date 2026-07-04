//
//  SummaryService.swift
//  Kurn
//
//  Builds the summary prompt from a meeting's transcripts and delegates to the
//  configured LLM provider. Pure value-in / value-out so it stays off SwiftData.
//  Transcripts short enough for one request go through a single pass; very long
//  meetings (2h+) are summarized in stages: each block is condensed into detailed
//  notes (map), then the notes are summarized with the user's template (reduce).
//

import Foundation

struct SummaryService {

    /// Transcripts at or below this size are summarized in a single request.
    /// ~80k chars ≈ 20k tokens — inside every supported model's context window
    /// with room for the system prompt and the summary itself, while keeping
    /// single-request latency inside the request timeout. A 2h meeting lands
    /// around 100k chars, so long meetings take the staged path.
    static let maxSinglePassChars = 80_000
    /// Size of each map-stage block when the transcript exceeds
    /// `maxSinglePassChars`. Blocks split on line boundaries only, so no
    /// `[mm:ss] Speaker: text` line is ever cut in half.
    static let mapBlockChars = 60_000

    /// Generate a structured summary for already-assembled transcript text.
    /// - Parameters:
    ///   - transcriptText: speaker-labelled, timestamped transcript of the whole
    ///     meeting.
    ///   - meetingTitle: included for light context in the prompt.
    ///   - provider: which vendor to use (resolved to a key via ProviderFactory).
    ///   - template: shapes the persona/focus and the summary's sections.
    ///   - onProgress: staged-path progress as (stage, totalStages); reported
    ///     off the main actor, single-pass summaries never call it.
    func generate(
        transcriptText: String,
        meetingTitle: String,
        provider: AIProvider,
        model: String,
        template: SummaryTemplate,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> SummaryResult {
        let trimmed = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.transcriptionFailed(
                NSLocalizedString("error.no_transcript", comment: "No transcript to summarize")
            )
        }

        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)

        guard trimmed.count > Self.maxSinglePassChars else {
            try Task.checkCancellation()
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

        return try await mapReduce(
            llm: llm,
            transcript: trimmed,
            meetingTitle: meetingTitle,
            template: template,
            onProgress: onProgress
        )
    }

    // MARK: - Staged summarization (map-reduce)

    /// Condense each transcript block into detailed intermediate notes, then
    /// summarize the combined notes with the user's chosen template. Blocks run
    /// sequentially to stay clear of vendor rate limits; the first failure
    /// aborts the whole summary with its original error.
    private func mapReduce(
        llm: LLMProvider,
        transcript: String,
        meetingTitle: String,
        template: SummaryTemplate,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> SummaryResult {
        let blocks = Self.splitTranscript(transcript, maxChars: Self.mapBlockChars)
        let totalStages = blocks.count + 1
        AppLog.transcription.atNotice.notice("summary: staged path blocks=\(blocks.count, privacy: .public) chars=\(transcript.count, privacy: .public)")

        var notes: [String] = []
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1, totalStages)
            let userPrompt = """
            Meeting title: \(meetingTitle)

            Transcript (part \(index + 1) of \(blocks.count)):
            \(block)
            """
            let partial = try await llm.summarize(
                systemPrompt: SummaryPrompt.system(for: Self.notesTemplate),
                userPrompt: userPrompt
            )
            notes.append(Self.markdownText(from: partial.sections))
            AppLog.transcription.atInfo.info("summary: map block \(index + 1, privacy: .public)/\(blocks.count, privacy: .public) done")
        }

        try Task.checkCancellation()
        onProgress?(totalStages, totalStages)
        let combinedNotes = notes.enumerated()
            .map { "Part \($0.offset + 1) of \(blocks.count):\n\($0.element)" }
            .joined(separator: "\n\n")
        let reducePrompt = """
        Meeting title: \(meetingTitle)

        The meeting was too long to process at once, so its transcript was split \
        into \(blocks.count) chronological parts and each part was condensed into \
        the detailed notes below. Treat these notes as the meeting transcript.

        Notes:
        \(combinedNotes)
        """
        return try await llm.summarize(
            systemPrompt: SummaryPrompt.system(for: template),
            userPrompt: reducePrompt
        )
    }

    /// Internal template for the map stage. Runs through the same
    /// `LLMProvider.summarize` JSON contract as user-facing summaries, so no
    /// provider changes are needed; its sections are rendered back to markdown
    /// and fed to the reduce stage. Never shown in the template picker.
    static let notesTemplate = SummaryTemplate(
        id: "internal-map-notes",
        name: "Intermediate notes",
        iconName: "note.text",
        instructions: """
        You are condensing ONE PART of a longer meeting into detailed \
        intermediate notes; another pass will write the final summary from \
        them, so completeness matters more than polish. Capture every \
        decision, action item (with owner and deadline when stated), open \
        question, key fact, number, date, and name, and keep the [mm:ss] \
        timestamps of important moments. Do not editorialize and do not drop \
        topics.
        """,
        sections: ["Discussion", "Decisions", "Action Items", "Open Questions"]
    )

    /// Split a transcript into blocks of at most `maxChars`, breaking only on
    /// line boundaries so `[mm:ss] Speaker: text` lines stay whole. Joining the
    /// blocks with a newline reproduces the input. A single line longer than
    /// `maxChars` becomes its own oversized block rather than being cut.
    static func splitTranscript(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }

        var blocks: [String] = []
        var currentLines: [String] = []
        var currentCount = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let added = currentLines.isEmpty ? line.count : line.count + 1
            if !currentLines.isEmpty && currentCount + added > maxChars {
                blocks.append(currentLines.joined(separator: "\n"))
                currentLines = [String(line)]
                currentCount = line.count
            } else {
                currentLines.append(String(line))
                currentCount += added
            }
        }
        if !currentLines.isEmpty {
            blocks.append(currentLines.joined(separator: "\n"))
        }
        return blocks
    }

    /// Render summary sections back into markdown text for the reduce prompt.
    static func markdownText(from sections: [SummarySection]) -> String {
        sections.map { section in
            var lines: [String] = []
            if !section.title.isEmpty { lines.append("## \(section.title)") }
            if !section.body.isEmpty { lines.append(section.body) }
            lines.append(contentsOf: section.items.map { "- \($0)" })
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// Generate a short 5–7 word meeting title from the transcript. Uses the
    /// same provider as the full summary but sends only a small excerpt and
    /// expects a one-line JSON reply, so it's fast and cheap. Best-effort:
    /// callers should catch and ignore errors rather than surfacing them.
    func generateTitle(
        transcriptText: String,
        provider: AIProvider,
        model: String
    ) async throws -> String {
        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        let excerpt = String(transcriptText.prefix(2_000))
        let system = """
        You generate short meeting titles. \
        Return ONLY valid JSON in this exact format with no other text: \
        {"sections":[{"title":"5 to 7 word title here","body":""}]}
        The title must be written in the same language as the transcript.
        """
        let result = try await llm.summarize(
            systemPrompt: system,
            userPrompt: "Transcript:\n\(excerpt)"
        )
        let title = result.sections.first?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            throw AppError.decodingError("empty title in response")
        }
        return title
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

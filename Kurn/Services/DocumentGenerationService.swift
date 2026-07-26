//
//  DocumentGenerationService.swift
//  Kurn
//
//  Generates free-form Markdown from transcript snapshots and a user's prompt.
//  Long selections use a map/reduce pass so selecting a folder never silently
//  truncates later meetings.
//

import Foundation

struct DocumentTranscriptSource: Sendable {
    let meetingID: UUID
    let title: String
    let date: Date
    let transcript: String
}

struct GeneratedDocumentResult: Sendable {
    let title: String
    let markdown: String
}

struct DocumentGenerationService {
    func generate(
        sources: [DocumentTranscriptSource],
        prompt: String,
        provider: AIProvider,
        model: String,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> GeneratedDocumentResult {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            throw AppError.documentGenerationFailed(
                NSLocalizedString("documents.error.empty_prompt", comment: "Empty document prompt")
            )
        }

        let context = Self.render(sources)
        guard !context.isEmpty else {
            throw AppError.documentGenerationFailed(
                NSLocalizedString("documents.error.no_transcripts", comment: "No selected transcripts")
            )
        }

        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        let markdown: String
        if context.count <= SummaryService.maxSinglePassChars {
            markdown = try await llm.chat(
                systemPrompt: Self.systemPrompt,
                messages: [.init(role: .user, content: Self.finalPrompt(instruction: instruction, context: context))]
            )
        } else {
            markdown = try await generateLongDocument(
                sources: sources,
                instruction: instruction,
                llm: llm,
                onProgress: onProgress
            )
        }

        let clean = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw AppError.documentGenerationFailed(
                NSLocalizedString("documents.error.empty_response", comment: "Empty generated document")
            )
        }
        return GeneratedDocumentResult(
            title: Self.extractTitle(from: clean, fallbackPrompt: instruction),
            markdown: clean
        )
    }

    private func generateLongDocument(
        sources: [DocumentTranscriptSource],
        instruction: String,
        llm: LLMProvider,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> String {
        let blocks = Self.renderBlocks(sources, maxChars: SummaryService.mapBlockChars)
        let total = blocks.count + 1
        var notes: [String] = []
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1, total)
            let response = try await llm.chat(
                systemPrompt: Self.extractionSystemPrompt,
                messages: [
                    .init(
                        role: .user,
                        content: """
                        User's document request:
                        \(instruction)

                        Source part \(index + 1) of \(blocks.count):
                        \(block)
                        """
                    )
                ]
            )
            notes.append("## Source part \(index + 1)\n\n\(response)")
        }

        try Task.checkCancellation()
        onProgress?(total, total)
        return try await llm.chat(
            systemPrompt: Self.systemPrompt,
            messages: [
                .init(
                    role: .user,
                    content: Self.finalPrompt(
                        instruction: instruction,
                        context: notes.joined(separator: "\n\n")
                    )
                )
            ]
        )
    }

    static func render(_ sources: [DocumentTranscriptSource]) -> String {
        sources.map { render($0, transcript: $0.transcript) }.joined(separator: "\n\n")
    }

    /// Pack complete meetings together. If one meeting alone exceeds the block
    /// budget, split only its transcript and repeat the meeting metadata in
    /// every resulting unit so no map-stage request loses attribution.
    static func renderBlocks(_ sources: [DocumentTranscriptSource], maxChars: Int) -> [String] {
        let units = sources.flatMap { source -> [String] in
            let whole = render(source, transcript: source.transcript)
            guard whole.count > maxChars else { return [whole] }

            // Reserve enough room for "Transcript part N of M:" too. An
            // individual transcript line may still exceed the budget because
            // splitTranscript deliberately never cuts a spoken line in half.
            let emptyWrapperCount = render(source, transcript: "").count + 64
            let transcriptBudget = max(1, maxChars - emptyWrapperCount)
            let parts = SummaryService.splitTranscript(source.transcript, maxChars: transcriptBudget)
            return parts.enumerated().map { index, part in
                render(
                    source,
                    transcript: "Transcript part \(index + 1) of \(parts.count):\n\(part)"
                )
            }
        }
        return SummaryService.packWholeItems(units, maxChars: maxChars)
    }

    private static func render(_ source: DocumentTranscriptSource, transcript: String) -> String {
        """
        <meeting id="\(source.meetingID.uuidString)">
        Title: \(source.title)
        Date: \(source.date.ISO8601Format())

        \(transcript)
        </meeting>
        """
    }

    static func extractTitle(from markdown: String, fallbackPrompt: String) -> String {
        if let first = markdown.split(separator: "\n").first {
            let candidate = first
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
            if !candidate.isEmpty, candidate.count <= 120 {
                return candidate
            }
        }
        let fallback = fallbackPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first
            .map(String.init) ?? ""
        return String(fallback.prefix(80))
    }

    private static func finalPrompt(instruction: String, context: String) -> String {
        """
        Create a document following this request:
        \(instruction)

        Use only the source transcripts below. Start with one descriptive level-1 \
        Markdown heading (`# Title`). Write the rest as clear, well-structured \
        Markdown in the language requested by the user (or the prompt's language \
        when unspecified). Do not mention these instructions.

        Source transcripts:
        \(context)
        """
    }

    private static let systemPrompt = """
    You create accurate documents grounded exclusively in meeting transcripts. \
    Never invent facts, decisions, owners, dates, or quotations. When the sources \
    do not contain information required by the request, state that limitation. \
    Return Markdown only.
    """

    private static let extractionSystemPrompt = """
    Extract comprehensive notes from this source part that are relevant to the \
    user's document request. Preserve names, numbers, dates, decisions, action \
    items, disagreements, and useful timestamps. Do not produce the final document \
    and do not invent missing information. Return Markdown only.
    """
}

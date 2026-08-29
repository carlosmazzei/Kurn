//
//  DocumentGenerationService.swift
//  Kurn
//
//  Generates free-form Markdown from transcript snapshots and a user's prompt.
//  Long selections use a map/reduce pass so selecting a folder never silently
//  truncates later meetings.
//

import Foundation
import KurnCore

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
        runID: OperationID = OperationID(),
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> GeneratedDocumentResult {
        let startedAt = Date()
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.generation.atNotice.notice(
            "document: start run=\(runID.value, privacy: .public) provider=\(provider.id, privacy: .public) model=\(model, privacy: .public) sources=\(sources.count, privacy: .public) promptChars=\(instruction.count, privacy: .public)"
        )
        guard !instruction.isEmpty else {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation",
                stage: "validation", outcome: .failed, code: "empty_prompt"
            ))
            throw AppError.documentGenerationFailed(
                NSLocalizedString("documents.error.empty_prompt", comment: "Empty document prompt")
            )
        }

        let context = Self.render(sources)
        guard !context.isEmpty else {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation",
                stage: "validation", outcome: .failed, code: "no_transcripts"
            ))
            throw AppError.documentGenerationFailed(
                NSLocalizedString("documents.error.no_transcripts", comment: "No selected transcripts")
            )
        }

        let llm: LLMProvider
        do {
            llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: "provider",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: Self.errorCode(error)
            ))
            throw error
        }

        let markdown: String
        if context.count <= SummaryService.maxSinglePassChars(for: provider) {
            AppLog.generation.atNotice.notice(
                "document: strategy run=\(runID.value, privacy: .public) path=single contextChars=\(context.count, privacy: .public)"
            )
            markdown = try await requestText(
                llm: llm,
                systemPrompt: Self.systemPrompt,
                message: Self.finalPrompt(instruction: instruction, context: context),
                stage: "single",
                runID: runID
            )
        } else {
            AppLog.generation.atNotice.notice(
                "document: strategy run=\(runID.value, privacy: .public) path=staged contextChars=\(context.count, privacy: .public)"
            )
            markdown = try await generateLongDocument(
                sources: sources,
                instruction: instruction,
                llm: llm,
                runID: runID,
                onProgress: onProgress
            )
        }

        let clean = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: "output",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: "empty_response"
            ))
            throw AppError.documentGenerationFailed(
                NSLocalizedString("documents.error.empty_response", comment: "Empty generated document")
            )
        }
        AppLog.generation.atNotice.notice(
            "document: complete run=\(runID.value, privacy: .public) elapsed=\(Self.duration(since: startedAt), privacy: .public)s outputChars=\(clean.count, privacy: .public)"
        )
        ReliabilityLog.record(ReliabilityEvent(
            operationID: runID, operation: "document_generation",
            outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(startedAt)
        ))
        return GeneratedDocumentResult(
            title: Self.extractTitle(from: clean, fallbackPrompt: instruction),
            markdown: clean
        )
    }

    private func generateLongDocument(
        sources: [DocumentTranscriptSource],
        instruction: String,
        llm: LLMProvider,
        runID: OperationID,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> String {
        let blocks = Self.renderBlocks(sources, maxChars: SummaryService.mapBlockChars(for: llm.provider))
        let total = blocks.count + 1
        AppLog.generation.atNotice.notice(
            "document: staged run=\(runID.value, privacy: .public) blocks=\(blocks.count, privacy: .public)"
        )
        var notes: [String] = []
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1, total)
            let response = try await requestText(
                llm: llm,
                systemPrompt: Self.extractionSystemPrompt,
                message: """
                User's document request:
                \(instruction)

                Source part \(index + 1) of \(blocks.count):
                \(block)
                """,
                stage: "map_\(index + 1)_of_\(blocks.count)",
                runID: runID
            )
            notes.append("## Source part \(index + 1)\n\n\(response)")
        }

        try Task.checkCancellation()
        onProgress?(total, total)
        return try await requestText(
            llm: llm,
            systemPrompt: Self.systemPrompt,
            message: Self.finalPrompt(
                instruction: instruction,
                context: notes.joined(separator: "\n\n")
            ),
            stage: "reduce",
            runID: runID
        )
    }

    private func requestText(
        llm: LLMProvider,
        systemPrompt: String,
        message: String,
        stage: String,
        runID: OperationID
    ) async throws -> String {
        let startedAt = Date()
        AppLog.generation.atInfo.info(
            "document: request run=\(runID.value, privacy: .public) stage=\(stage, privacy: .public) inputChars=\(message.count, privacy: .public) maxOutputTokens=\(TextGenerationOptions.document.maxOutputTokens, privacy: .public)"
        )
        do {
            let response = try await llm.chat(
                systemPrompt: systemPrompt,
                messages: [.init(role: .user, content: message)],
                options: .document
            )
            AppLog.generation.atInfo.info(
                "document: response run=\(runID.value, privacy: .public) stage=\(stage, privacy: .public) elapsed=\(Self.duration(since: startedAt), privacy: .public)s outputChars=\(response.count, privacy: .public)"
            )
            return response
        } catch is CancellationError {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: stage,
                outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            throw CancellationError()
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: stage,
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: Self.errorCode(error)
            ))
            throw error
        }
    }

    private static func duration(since date: Date) -> String {
        String(format: "%.3f", Date().timeIntervalSince(date))
    }

    private static func errorCode(_ error: Error) -> String {
        (error as? AppError)?.logCode ?? "unexpected"
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

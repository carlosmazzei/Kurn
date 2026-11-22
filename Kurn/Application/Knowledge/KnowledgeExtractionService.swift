import AgentHarness
import Foundation
import KurnCore

struct KnowledgeExtractionAuthorization: Sendable {
    var featureEnabled: Bool
    var policies: [KnowledgeProcessingPolicy]
    var sourceClassifications: [KnowledgeClassification]
    var userConsentedToRemote: Bool = false

    func decision(for provider: AIProvider) -> KnowledgePolicyDecision {
        let destination: KnowledgeDestination = provider.kind == .appleOnDevice ? .onDevice : .remote(providerID: provider.id)
        return KnowledgePolicyEvaluator.evaluate(KnowledgeProcessingRequest(
            operation: .extraction, destination: destination, sourceClassifications: sourceClassifications,
            userConsentedToRemote: userConsentedToRemote
        ), under: policies, featureEnabled: featureEnabled)
    }
}

enum KnowledgeExtractionServiceError: String, Error {
    case policyDenied = "policy_denied"
    case emptyTranscript = "empty_transcript"
    case segmentExceedsBudget = "segment_exceeds_budget"
    case requestLimit = "request_limit"
    case incompleteCoverage = "incomplete_coverage"
}

/// Value-in/value-out only. Not wired to Settings, scheduling or persistence.
/// The host must recheck revision and policy at the K1.5 commit boundary.
struct KnowledgeExtractionService: Sendable {
    enum Strategy: String, Sendable { case fullContext, blocks }
    struct Result: Sendable {
        let transcriptFingerprint: String
        let strategy: Strategy
        /// Local refs are scoped by the array index; never flatten these before
        /// entity resolution, or e1/a1 from independent passes would collide.
        let passes: [KnowledgeExtraction]
        let examinedSegmentIDs: [String]
        let targetedPassCount: Int
    }

    // swiftlint:disable:next function_parameter_count
    func extract(
        segments: [TranscriptSegment],
        language: String,
        context: KnowledgeExtractionContext,
        llm: any LLMProvider,
        budget: ContextBudget,
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization
    ) async throws -> Result {
        try Task.checkCancellation()
        try await authorize(llm, authorization)
        let revision = try KnowledgeTranscriptRevision(segments: segments, language: language)
        guard !segments.isEmpty else { throw KnowledgeExtractionServiceError.emptyTranscript }
        let sources = zip(revision.snapshot.sourceSegments, segments).map { source, segment in
            KnowledgeExtractionPrompt.Source(id: source.id, speaker: segment.speakerLabel,
                startMs: source.startMs, endMs: source.endMs, text: source.text)
        }
        let options = TextGenerationOptions.knowledgeExtraction(for: llm.provider)
        let groups = try plan(sources, context: context, budget: budget, outputTokens: options.maxOutputTokens)
        let initial = try await runGroups(groups, context: context, revision: revision, llm: llm,
            authorization: authorization, remainingPasses: 64, options: options)
        let examined = Set(initial.documents.flatMap(\.examinedSegmentIDs))
        // Explicit coverage of all anchors implies start/middle/end coverage.
        // Apply the same input AND output planning to the one targeted round.
        let missing = sources.filter { !examined.contains($0.id) }
        let targeted = try missing.isEmpty ? [] : plan(missing, context: context, budget: budget, outputTokens: options.maxOutputTokens)
        let recovery = try await runGroups(targeted, context: context, revision: revision, llm: llm,
            authorization: authorization, remainingPasses: 64 - initial.attempts, options: options)
        let passes = initial.documents + recovery.documents
        guard Set(passes.flatMap(\.examinedSegmentIDs)).count == sources.count else {
            throw KnowledgeExtractionServiceError.incompleteCoverage
        }
        let strategy: Strategy = groups.count == 1 && !initial.wasSplit ? .fullContext : .blocks
        return Result(transcriptFingerprint: revision.fingerprint, strategy: strategy, passes: passes,
            examinedSegmentIDs: sources.map(\.id), targetedPassCount: recovery.attempts)
    }

    /// Reserve half the output allowance for assertions/evidence. UUID coverage
    /// alone must never consume the full response before any knowledge fits.
    private func outputFits(_ sources: [KnowledgeExtractionPrompt.Source], outputTokens: Int) throws -> Bool {
        let data = try JSONEncoder().encode(sources.map(\.id))
        return TokenEstimate.tokens(in: String(decoding: data, as: UTF8.self)) + 100 <= outputTokens / 2
    }

    private func plan(
        _ sources: [KnowledgeExtractionPrompt.Source], context: KnowledgeExtractionContext, budget: ContextBudget, outputTokens: Int
    ) throws -> [[KnowledgeExtractionPrompt.Source]] {
        if budget.fits(try KnowledgeExtractionPrompt.input(sources, context: context)), try outputFits(sources, outputTokens: outputTokens) { return [sources] }
        return try blocks(sources, context: context, budget: budget, outputTokens: outputTokens)
    }

    private struct Batch {
        var documents: [KnowledgeExtraction] = []
        var attempts = 0
        var wasSplit = false
    }

    // swiftlint:disable:next function_parameter_count
    private func runGroups(
        _ groups: [[KnowledgeExtractionPrompt.Source]], context: KnowledgeExtractionContext,
        revision: KnowledgeTranscriptRevision, llm: any LLMProvider,
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization, remainingPasses: Int, options: TextGenerationOptions
    ) async throws -> Batch {
        guard groups.count <= remainingPasses else { throw KnowledgeExtractionServiceError.requestLimit }
        var result = Batch()
        for (index, group) in groups.enumerated() {
            result.attempts += 1
            do {
                result.documents.append(try await run(group, context: context, revision: revision, llm: llm, authorization: authorization, options: options))
            } catch AppError.generationTruncated {
                // One split only, preserving original anchors. A single huge
                // segment or a second truncation fails explicitly, never loops.
                guard group.count > 1 else { throw AppError.generationTruncated }
                guard result.attempts + 2 + (groups.count - index - 1) <= remainingPasses else {
                    throw KnowledgeExtractionServiceError.requestLimit
                }
                result.wasSplit = true
                let middle = group.count / 2
                for half in [Array(group[..<middle]), Array(group[middle...])] {
                    result.attempts += 1
                    result.documents.append(try await run(half, context: context, revision: revision, llm: llm, authorization: authorization, options: options))
                }
            }
        }
        return result
    }

    private func blocks(
        _ sources: [KnowledgeExtractionPrompt.Source], context: KnowledgeExtractionContext, budget: ContextBudget, outputTokens: Int
    ) throws -> [[KnowledgeExtractionPrompt.Source]] {
        let mapBudget = ContextBudget(inputTokens: budget.mapBlockTokens, mapBlockTokens: budget.mapBlockTokens)
        var groups: [[KnowledgeExtractionPrompt.Source]] = []
        var current: [KnowledgeExtractionPrompt.Source] = []
        for source in sources {
            let inputFits = mapBudget.fits(try KnowledgeExtractionPrompt.input(current + [source], context: context))
            let coverageFits = try outputFits(current + [source], outputTokens: outputTokens)
            if !inputFits || !coverageFits {
                guard !current.isEmpty else { throw KnowledgeExtractionServiceError.segmentExceedsBudget }
                groups.append(current)
                current = []
            }
            guard mapBudget.fits(try KnowledgeExtractionPrompt.input([source], context: context)) else {
                throw KnowledgeExtractionServiceError.segmentExceedsBudget
            }
            current.append(source)
        }
        if !current.isEmpty { groups.append(current) }
        guard groups.count <= 64 else { throw KnowledgeExtractionServiceError.requestLimit }
        return groups
    }

    // swiftlint:disable:next function_parameter_count
    private func run(
        _ sources: [KnowledgeExtractionPrompt.Source], context: KnowledgeExtractionContext,
        revision: KnowledgeTranscriptRevision, llm: any LLMProvider,
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization, options: TextGenerationOptions
    ) async throws -> KnowledgeExtraction {
        try Task.checkCancellation()
        try await authorize(llm, authorization)
        let input = try KnowledgeExtractionPrompt.input(sources, context: context)
        let system = KnowledgeExtractionPrompt.system + "\n" + KnowledgeExtractionPrompt.vocabulary
        // A repair is a fresh request with a fixed diagnostic and the original
        // input. Never echo an untrusted/oversized model reply into a new prompt.
        var diagnostic = ""
        for attempt in 0...1 {
            try Task.checkCancellation()
            try await authorize(llm, authorization)
            let reply = try await llm.chat(systemPrompt: system + diagnostic,
                messages: [ChatMessage(role: .user, content: input)], options: options)
            try Task.checkCancellation()
            do {
                let document = try KnowledgeExtraction.decode(Data(reply.utf8), segments: revision.snapshot.sourceSegments)
                guard Set(document.examinedSegmentIDs).isSubset(of: Set(sources.map(\.id))) else {
                    throw KnowledgeExtractionError.invalidCoverage
                }
                return document
            } catch let error as KnowledgeExtractionError {
                guard attempt == 0 else { throw error }
                diagnostic = "\nThe previous response failed host validation (\(error.rawValue)). Return a complete corrected JSON object."
            }
        }
        // The bounded loop either returns a validated result or throws.
        throw KnowledgeExtractionServiceError.incompleteCoverage
    }

    private func authorize(
        _ llm: any LLMProvider, _ authorization: @Sendable () async -> KnowledgeExtractionAuthorization
    ) async throws {
        guard await authorization().decision(for: llm.provider).isAllowed else { throw KnowledgeExtractionServiceError.policyDenied }
    }
}

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
        let fullInput = try KnowledgeExtractionPrompt.input(sources, context: context)
        let strategy: Strategy = budget.fits(fullInput) ? .fullContext : .blocks
        let groups = try strategy == .fullContext ? [sources] : blocks(sources, context: context, budget: budget)
        var passes: [KnowledgeExtraction] = []
        var examined: Set<String> = []
        for group in groups {
            let pass = try await run(group, context: context, revision: revision, llm: llm, authorization: authorization)
            passes.append(pass)
            examined.formUnion(pass.examinedSegmentIDs)
        }
        // Explicit coverage of all anchors implies start/middle/end coverage.
        // One bounded targeted round addresses omissions; no silent truncation,
        // endless extraction loop or second synthesis over generated text.
        let missing = sources.filter { !examined.contains($0.id) }
        let targeted = try missing.isEmpty ? [] : blocks(missing, context: context, budget: budget)
        guard groups.count + targeted.count <= 64 else { throw KnowledgeExtractionServiceError.requestLimit }
        for group in targeted {
            let pass = try await run(group, context: context, revision: revision, llm: llm, authorization: authorization)
            passes.append(pass)
            examined.formUnion(pass.examinedSegmentIDs)
        }
        guard examined.count == sources.count else { throw KnowledgeExtractionServiceError.incompleteCoverage }
        return Result(transcriptFingerprint: revision.fingerprint, strategy: strategy, passes: passes,
            examinedSegmentIDs: sources.map(\.id), targetedPassCount: targeted.count)
    }

    private func blocks(
        _ sources: [KnowledgeExtractionPrompt.Source], context: KnowledgeExtractionContext, budget: ContextBudget
    ) throws -> [[KnowledgeExtractionPrompt.Source]] {
        let mapBudget = ContextBudget(inputTokens: budget.mapBlockTokens, mapBlockTokens: budget.mapBlockTokens)
        var groups: [[KnowledgeExtractionPrompt.Source]] = []
        var current: [KnowledgeExtractionPrompt.Source] = []
        for source in sources {
            if !mapBudget.fits(try KnowledgeExtractionPrompt.input(current + [source], context: context)) {
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
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization
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
                messages: [ChatMessage(role: .user, content: input)], options: .document)
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

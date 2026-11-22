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
        /// Vendor-reported tokens across every pass and repair; nil when the
        /// provider reports none (on-device).
        var usage: TokenUsage?
        /// Well-formed facts dropped for breaking a domain rule.
        var discardedFacts = 0
    }

    /// Per-extraction accumulator, bound task-locally so passes and repairs
    /// add to it without threading it through every helper.
    final class Tally: @unchecked Sendable {
        @TaskLocal static var current: Tally?
        let usage = TokenUsageSink()
        private let lock = NSLock()
        private var discarded = 0
        var discardedFacts: Int { lock.withLock { discarded } }
        func discard(_ count: Int) { lock.withLock { discarded += count } }
    }

    // swiftlint:disable:next function_parameter_count
    func extract(
        segments: [TranscriptSegment],
        language: String,
        context: KnowledgeExtractionContext,
        llm: any LLMProvider,
        budget: ContextBudget,
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization,
        model: String? = nil,
        onPass: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async throws -> Result {
        let tally = Tally()
        var result = try await Tally.$current.withValue(tally) {
            try await extractPasses(segments: segments, language: language, context: context, llm: llm,
                budget: budget, authorization: authorization, model: model, onPass: onPass)
        }
        result.usage = tally.usage.total
        result.discardedFacts = tally.discardedFacts
        return result
    }

    // swiftlint:disable:next function_parameter_count
    private func extractPasses(
        segments: [TranscriptSegment], language: String, context: KnowledgeExtractionContext, llm: any LLMProvider,
        budget: ContextBudget, authorization: @Sendable () async -> KnowledgeExtractionAuthorization,
        model: String?, onPass: (@Sendable (_ completed: Int, _ total: Int) async -> Void)?
    ) async throws -> Result {
        try Task.checkCancellation()
        try await authorize(llm, authorization)
        let revision = try KnowledgeTranscriptRevision(segments: segments, language: language)
        guard !segments.isEmpty else { throw KnowledgeExtractionServiceError.emptyTranscript }
        let sources = zip(revision.snapshot.sourceSegments, segments).map { source, segment in
            KnowledgeExtractionPrompt.Source(id: source.id, speaker: segment.speakerLabel,
                startMs: source.startMs, endMs: source.endMs, text: source.text)
        }
        let options = TextGenerationOptions.knowledgeExtraction(
            for: llm.provider, modelOutputLimit: model.flatMap(ModelContextCatalog.maxOutputTokens(for:)))
        let groups = try plan(sources, context: context, budget: budget, outputTokens: options.maxOutputTokens)
        let initial = try await runGroups(groups, context: context, revision: revision, llm: llm,
            authorization: authorization, remainingPasses: 64, options: options, onPass: onPass)
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
        authorization: @Sendable () async -> KnowledgeExtractionAuthorization, remainingPasses: Int, options: TextGenerationOptions,
        onPass: (@Sendable (Int, Int) async -> Void)? = nil
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
                AppLog.knowledge.atNotice.notice("knowledge extraction pass truncated segments=\(group.count, privacy: .public) maxOutputTokens=\(options.maxOutputTokens, privacy: .public) splittingInto=\(group.count > 1 ? 2 : 0, privacy: .public)")
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
            await onPass?(index + 1, groups.count)
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
        // Short per-pass aliases ("s1"…"sN") instead of 36-character UUIDs: a
        // long meeting asked the model to copy hundreds of UUIDs back, and one
        // mistyped ID rejected the whole pass. Mapped back before validation.
        let aliases = Self.aliases(for: sources)
        let input = try KnowledgeExtractionPrompt.input(Self.aliased(sources, aliases), context: context)
        let system = KnowledgeExtractionPrompt.system + "\n" + KnowledgeExtractionPrompt.vocabulary
        // A repair is a fresh request with a fixed diagnostic and the original
        // input. Never echo an untrusted/oversized model reply into a new prompt.
        var diagnostic = ""
        for attempt in 0...1 {
            try Task.checkCancellation()
            try await authorize(llm, authorization)
            let startedAt = Date()
            AppLog.knowledge.atNotice.notice("knowledge extraction pass start attempt=\(attempt + 1, privacy: .public) segments=\(sources.count, privacy: .public) provider=\(llm.provider.id, privacy: .public) maxOutputTokens=\(options.maxOutputTokens, privacy: .public) timeout=\(Int(options.timeout), privacy: .public)s")
            let reply: String
            do {
                let passUsage = TokenUsageSink()
                reply = try await TokenUsageRecording.$sink.withValue(passUsage) {
                    try await llm.chat(systemPrompt: system + diagnostic,
                        messages: [ChatMessage(role: .user, content: input)], options: options)
                }
                if let used = passUsage.total {
                    Tally.current?.usage.add(used)
                    AppLog.knowledge.atNotice.notice("knowledge extraction pass usage attempt=\(attempt + 1, privacy: .public) promptTokens=\(used.promptTokens, privacy: .public) completionTokens=\(used.completionTokens, privacy: .public)")
                }
            } catch {
                AppLog.knowledge.atError.error("knowledge extraction pass request failed attempt=\(attempt + 1, privacy: .public) elapsed=\(Int(Date().timeIntervalSince(startedAt)), privacy: .public)s code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                throw error
            }
            try Task.checkCancellation()
            let data = Self.dealiased(KnowledgeExtraction.normalizedReply(reply), aliases: aliases)
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            do {
                let report = try KnowledgeExtraction.decodeReport(data, segments: revision.snapshot.sourceSegments)
                let document = report.extraction
                Tally.current?.discard(report.discardedAssertions)
                if report.discardedAssertions + report.discardedEvents > 0 {
                    AppLog.knowledge.atNotice.notice("knowledge extraction pass discarded invalid facts=\(report.discardedAssertions, privacy: .public) events=\(report.discardedEvents, privacy: .public) kept=\(document.assertions.count, privacy: .public)")
                }
                guard Set(document.examinedSegmentIDs).isSubset(of: Set(sources.map(\.id))) else {
                    throw KnowledgeExtractionError.invalidCoverage
                }
                AppLog.knowledge.atNotice.notice("knowledge extraction pass ok attempt=\(attempt + 1, privacy: .public) elapsed=\(elapsed, privacy: .public)s replyBytes=\(data.count, privacy: .public) assertions=\(document.assertions.count, privacy: .public)")
                return document
            } catch let error as KnowledgeExtractionError {
                // Structural path only (schema key names and indices), never
                // model text — safe to log publicly and to send in the repair.
                let location = KnowledgeExtractionShape.diagnose(data) ?? Self.decodingPath(data) ?? "content"
                AppLog.knowledge.atError.error("knowledge extraction pass rejected attempt=\(attempt + 1, privacy: .public) elapsed=\(elapsed, privacy: .public)s replyBytes=\(data.count, privacy: .public) code=\(error.rawValue, privacy: .public) at=\(location, privacy: .public)")
                guard attempt == 0 else { throw error }
                diagnostic = "\nThe previous response failed host validation (\(error.rawValue) at \(location)). "
                    + "Return ONLY one complete JSON object with exactly the keys described above — no Markdown, no prose, "
                    + "every required key present (use [] for empty arrays), no extra keys."
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

    static func aliases(for sources: [KnowledgeExtractionPrompt.Source]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: sources.enumerated().map { ("s\($0.offset + 1)", $0.element.id) })
    }

    static func aliased(_ sources: [KnowledgeExtractionPrompt.Source], _ aliases: [String: String]) -> [KnowledgeExtractionPrompt.Source] {
        let byID = Dictionary(uniqueKeysWithValues: aliases.map { ($0.value, $0.key) })
        return sources.map { .init(id: byID[$0.id] ?? $0.id, speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs, text: $0.text) }
    }

    /// Replaces aliases with the real segment IDs in exactly the three
    /// segment-reference fields; anything else (and any unknown alias) is left
    /// untouched for the strict validator to judge. Non-JSON passes through.
    static func dealiased(_ data: Data, aliases: [String: String]) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        func map(_ value: Any?) -> Any? {
            if let id = value as? String { return aliases[id] ?? id }
            if let ids = value as? [Any] { return ids.map { ($0 as? String).map { aliases[$0] ?? $0 } ?? $0 } }
            return value
        }
        if let ids = root["examinedSegmentIDs"] { root["examinedSegmentIDs"] = map(ids) }
        if let assertions = root["assertions"] as? [[String: Any]] {
            root["assertions"] = assertions.map { item -> [String: Any] in
                var item = item
                if let id = item["attributedToSegmentID"] { item["attributedToSegmentID"] = map(id) }
                if let evidence = item["evidence"] as? [[String: Any]] {
                    item["evidence"] = evidence.map { entry -> [String: Any] in
                        var entry = entry
                        if let ids = entry["segmentIDs"] { entry["segmentIDs"] = map(ids) }
                        return entry
                    }
                }
                return item
            }
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// Where Codable rejected a shape-valid reply — typically a value outside
    /// a vocabulary (an unknown predicate or kind). Only coding-path keys
    /// (schema names) and indices are reported, never the offending value.
    static func decodingPath(_ data: Data) -> String? {
        do {
            _ = try JSONDecoder().decode(KnowledgeExtraction.self, from: data)
            return nil
        } catch let DecodingError.dataCorrupted(context) {
            return path(context.codingPath) + ": value outside the vocabulary"
        } catch let DecodingError.typeMismatch(_, context) {
            return path(context.codingPath) + ": wrong type"
        } catch let DecodingError.valueNotFound(_, context) {
            return path(context.codingPath) + ": null value"
        } catch {
            return nil
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

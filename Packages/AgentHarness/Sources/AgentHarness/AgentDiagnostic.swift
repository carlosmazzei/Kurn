import Foundation

/// Content-free execution facts. The vocabulary deliberately cannot accept tool arguments,
/// provider payloads, error descriptions, questions or excerpts.
public struct AgentDiagnostic: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case runStarted, runFinished, runFailed, runCancelled
        case contextCheck, compactionStarted, compactionFinished, compactionFailed, compactionSkipped
        case requestStarted, requestFinished, requestFailed
        case summaryStarted, summaryFinished, summaryFailed
        case limitReached, toolRequested, toolFinished, toolSkipped, wrapUpStarted, wrapUpFinished
        case payloadClipped, payloadPaged
        case budgetExtended
        case budgetExtensionDenied
        case outputBudgetExtended, outputBudgetExtensionDenied
        case outputRetryStarted, outputRetryDenied
        case requestRetryScheduled
        case outputBudgetAdjusted, replayPrepared
        case toolValidationFailed, toolPolicyDenied, toolProgress, toolAborted, toolRegistryRejected
    }
    public enum Metric: String, Codable, Sendable, CodingKeyRepresentable {
        case contextTokens, thresholdTokens, retainedTokens, afterTokens, forced
        case turnIndex, toolCalls, maxToolCalls, maxTurns, blockedCalls, callOrdinal
        case inputTokens, outputTokens, maxOutputTokens, messageCount, toolCount, durationMs
        case availableScalars, returnedScalars, hasMore, isError
        case omittedCharacters
        case omittedScalars, omittedItems, deferredScalars, deferredItems
        case searchResultLimit, searchWindowFull
        case selectedSources, selectedParts, estimatedReadPages, progressCalls
        case serializedToolOmittedCharacters, fittedHistoryOmittedCharacters
        case returnedItems, mutationsCommitted
        case hardMaxTurns, hardMaxToolCalls, minimumProgress, idleCalls
        case hardMaxOutputTokens, previousMaxOutputTokens, outputRetries
        case contextSafetyTokens, contextSafetyRelaxed, availableOutputTokens, outputCapacityFallback
        case sentMaxOutputTokens
        case contentBlocks, thinkingBlocks, invalidToolCalls, incompleteToolCalls, protocolFailure, modelStopReason
        case omittedMessages, omittedThinkingBlocks, omittedImages, omittedNamespaces, normalizedCallIDs, sanitizedArguments, strippedSignatures
        case visibleTextScalars, streamedText, returnedToolCalls, discardedToolCalls, outputLimited, usageReported, reasoningTokens, costLimitReached
        case toolPhase, completedItems
        case requestAttempt, retryDelayMs
    }

    public let runID: UUID
    public let sequence: Int
    public let recordedAt: Date
    public let correlation: AgentDiagnosticCorrelation?
    public let resolutionID: UUID?
    public let kind: Kind
    public let metrics: [Metric: Int]
    public let stopReason: AgentRunStopReason?

    public init(runID: UUID, sequence: Int, kind: Kind, metrics: [Metric: Int] = [:],
                stopReason: AgentRunStopReason? = nil, resolutionID: UUID? = nil, recordedAt: Date = Date(),
                correlation: AgentDiagnosticCorrelation? = nil) {
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
        self.metrics = metrics
        self.stopReason = stopReason
        self.resolutionID = resolutionID
        self.recordedAt = recordedAt
        self.correlation = correlation
    }

    public var logLine: String {
        let numbers = metrics.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
        return (["agent.\(kind.rawValue)", "run=\(runID)", "sequence=\(sequence)"]
                + correlation.map { $0.logFields }.defaultingToEmpty
                + resolutionID.map { ["resolution=\($0)"] }.defaultingToEmpty
                + stopReason.map { ["reason=\($0.rawValue)"] }.defaultingToEmpty + numbers).joined(separator: " ")
    }
}

private extension Optional where Wrapped == [String] {
    var defaultingToEmpty: [String] { self ?? [] }
}

/// A synchronous sink is independent of the UI consumer, so cancelling/dismissing the view
/// cannot suppress the terminal diagnostic. No event is sampled here.
final class AgentTraceEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private let runID: UUID
    let sessionID: String
    private var requestID: String?
    private var invocationID: String?
    private var invocationRequestID: String?
    private let resolutionID: UUID?
    private let events: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let sink: @Sendable (AgentDiagnostic) -> Void

    init(events: AsyncThrowingStream<AgentEvent, Error>.Continuation, resolutionID: UUID?,
         sink: @escaping @Sendable (AgentDiagnostic) -> Void, context: AgentRunContext = AgentRunContext()) {
        self.events = events
        runID = context.runID
        sessionID = context.sessionID
        self.resolutionID = resolutionID
        self.sink = sink
    }

    func beginRequest(_ request: AgentRequestIdentity) {
        lock.withLock { requestID = request.id; invocationID = nil; invocationRequestID = nil }
        events.yield(.requestStarted(request))
    }

    /// End only the matching attempt; a deferred cleanup cannot erase a newer request.
    func endRequest(_ request: AgentRequestIdentity) {
        lock.withLock { if requestID == request.id { requestID = nil } }
    }

    func beginInvocation(_ invocation: AgentToolInvocation) {
        lock.withLock { invocationRequestID = invocation.requestID; invocationID = invocation.id }
        events.yield(.invocationRegistered(invocation))
    }

    func endInvocation() { lock.withLock { invocationID = nil; invocationRequestID = nil } }

    func register(_ invocation: AgentToolInvocation) { events.yield(.invocationRegistered(invocation)) }

    func record(_ kind: AgentDiagnostic.Kind, metrics: [AgentDiagnostic.Metric: Int] = [:],
                reason: AgentRunStopReason? = nil, invocation: AgentToolInvocation? = nil) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let event = AgentDiagnostic(runID: runID, sequence: sequence, kind: kind, metrics: metrics,
                                    stopReason: reason, resolutionID: resolutionID,
                                    correlation: AgentDiagnosticCorrelation(sessionID: sessionID,
                                        requestID: invocation?.requestID ?? invocationRequestID ?? requestID, invocationID: invocation?.id ?? invocationID))
        sink(event)
        events.yield(.diagnostic(event))
    }
}

/// Opaque local identifiers only; provider payloads and credentials cannot be logged here.
public struct AgentDiagnosticCorrelation: Codable, Sendable, Equatable {
    public let sessionID: String
    public let requestID: String?
    public let invocationID: String?

    public init(sessionID: String, requestID: String? = nil, invocationID: String? = nil) {
        self.sessionID = sessionID; self.requestID = requestID; self.invocationID = invocationID
    }

    private static func logToken(_ id: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.addingPercentEncoding(withAllowedCharacters: safe) ?? "invalid"
    }

    var logFields: [String] {
        ["session=\(Self.logToken(sessionID))"] + requestID.map { ["request=\(Self.logToken($0))"] }.defaultingToEmpty
            + invocationID.map { ["invocation=\(Self.logToken($0))"] }.defaultingToEmpty
    }
}

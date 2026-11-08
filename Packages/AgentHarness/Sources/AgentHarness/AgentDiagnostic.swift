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
    }

    public let runID: UUID
    public let sequence: Int
    public let recordedAt: Date
    public let resolutionID: UUID?
    public let kind: Kind
    public let metrics: [Metric: Int]
    public let stopReason: AgentRunStopReason?

    public init(runID: UUID, sequence: Int, kind: Kind, metrics: [Metric: Int] = [:],
                stopReason: AgentRunStopReason? = nil, resolutionID: UUID? = nil, recordedAt: Date = Date()) {
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
        self.metrics = metrics
        self.stopReason = stopReason
        self.resolutionID = resolutionID
        self.recordedAt = recordedAt
    }

    public var logLine: String {
        let numbers = metrics.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
        return (["agent.\(kind.rawValue)", "run=\(runID)", "sequence=\(sequence)"]
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
    private let runID = UUID()
    private let resolutionID: UUID?
    private let events: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let sink: @Sendable (AgentDiagnostic) -> Void

    init(events: AsyncThrowingStream<AgentEvent, Error>.Continuation, resolutionID: UUID?,
         sink: @escaping @Sendable (AgentDiagnostic) -> Void) {
        self.events = events
        self.resolutionID = resolutionID
        self.sink = sink
    }

    func record(_ kind: AgentDiagnostic.Kind, metrics: [AgentDiagnostic.Metric: Int] = [:],
                reason: AgentRunStopReason? = nil) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let event = AgentDiagnostic(runID: runID, sequence: sequence, kind: kind, metrics: metrics,
                                    stopReason: reason, resolutionID: resolutionID)
        sink(event)
        events.yield(.diagnostic(event))
    }
}

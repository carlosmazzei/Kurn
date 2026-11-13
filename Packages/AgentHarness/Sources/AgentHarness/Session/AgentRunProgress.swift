import Foundation

/// Where a run is, and on what (NH05): its phase with the turn, request and tool calls it is
/// working on, reduced from the run's events. It is a projection for presentation, not a
/// canonical record, so it never blocks or orders persistence.
///
/// `compacting` covers a context compaction between `compactionStarted` and its finish, failure
/// or skip; `retryWaiting` covers an output-limit retry from `outputRetryStarted` until its new
/// request starts. A host owner adds its own states around these (cancellation, settlement);
/// a tool confirmation would be `waitingForUser`, which no event reports yet.
public struct AgentRunProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case preparing, streaming, executingTools, compacting, retryWaiting, finished
    }

    public private(set) var phase: Phase = .preparing
    /// The current model turn, zero-based like `AgentEvent.turnStarted`.
    public private(set) var turnIndex: Int?
    /// The request in flight, or the last one sent.
    public private(set) var request: AgentRequestIdentity?
    /// Tool calls started and not yet finished, in start order.
    public private(set) var activeCallIDs: [String] = []
    /// Local invocation identities registered for the current turn's calls, keyed by call ID.
    public private(set) var invocations: [String: AgentToolInvocation] = [:]
    /// The phase a compaction interrupted, restored when it ends.
    private var resumePhase: Phase?

    public init() {}

    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case .runStarted:
            self = AgentRunProgress()
        case .requestStarted(let identity):
            request = identity
            enter(.streaming)
        case .turnStarted(let index):
            turnIndex = index
            invocations = [:]
            enter(.streaming)
        case .textDelta, .modelContent:
            if phase == .preparing || phase == .retryWaiting { enter(.streaming) }
        case .invocationRegistered(let invocation):
            invocations[invocation.callID] = invocation
        case .toolStarted(let callID, _, _):
            if !activeCallIDs.contains(callID) { activeCallIDs.append(callID) }
            enter(.executingTools)
        case .toolFinished(let callID, _, _, _):
            activeCallIDs.removeAll { $0 == callID }
        case .diagnostic(let diagnostic):
            applyDiagnostic(diagnostic.kind)
        case .runFinished:
            activeCallIDs = []
            resumePhase = nil
            phase = .finished
        case .messageAppended, .contextResolved, .toolProgress, .contextCompacted, .usage:
            break
        }
    }

    private mutating func applyDiagnostic(_ kind: AgentDiagnostic.Kind) {
        switch kind {
        case .compactionStarted:
            guard phase != .compacting, phase != .finished else { return }
            resumePhase = phase
            phase = .compacting
        case .compactionFinished, .compactionFailed, .compactionSkipped:
            guard phase == .compacting else { return }
            phase = resumePhase ?? .preparing
            resumePhase = nil
        case .outputRetryStarted:
            guard phase != .finished else { return }
            phase = .retryWaiting
        default:
            break
        }
    }

    private mutating func enter(_ next: Phase) {
        guard phase != .finished else { return }
        if phase == .compacting { resumePhase = next } else { phase = next }
    }
}

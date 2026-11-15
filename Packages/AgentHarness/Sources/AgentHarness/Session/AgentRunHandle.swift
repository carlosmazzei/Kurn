import Foundation

/// Observation can lag or detach without affecting execution. Completion is the producer's
/// completion, not the observation iterator ending. Canonical persistence is never buffered here.
public struct AgentRunHandle: Sendable {
    public let events: AsyncThrowingStream<AgentEvent, Error>
    let task: Task<AgentRunOutcome, Error>

    public func cancel() { task.cancel() }
    public func result() async throws -> AgentRunOutcome { try await task.value }
}

/// How an owned run's disposable observation stream buffers events.
public enum AgentRunObservation: Sendable, Equatable {
    /// The newest 128 events; a slow observer sees a gap, never stalls the run.
    case bounded
    /// Every event, for a presentation reducer that cannot tolerate a gap. Memory grows with an
    /// observer that stops reading; the owner still cancels and awaits `result()` explicitly.
    case complete
}

import Foundation

/// Observation can lag or detach without affecting execution. Completion is the producer's
/// completion, not the observation iterator ending. Canonical persistence is never buffered here.
public struct AgentRunHandle: Sendable {
    public let events: AsyncThrowingStream<AgentEvent, Error>
    let task: Task<AgentRunOutcome, Error>

    public func cancel() { task.cancel() }
    public func result() async throws -> AgentRunOutcome { try await task.value }
}

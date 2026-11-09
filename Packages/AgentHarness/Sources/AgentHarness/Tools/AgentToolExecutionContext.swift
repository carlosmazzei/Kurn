import Foundation

/// Content-free progress. UI text and structured output belong to the terminal result.
public struct AgentToolProgress: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case validating, authorizing, executing, committing, committed, recoveredCommit }
    public let phase: Phase
    public let completed: Int?
    public init(_ phase: Phase, completed: Int? = nil) { self.phase = phase; self.completed = completed.map { max(0, $0) } }
}

/// One fence shared by all copies of the context; callbacks after terminal completion are ignored.
public final class AgentToolExecutionContext: @unchecked Sendable {
    public let sessionID: String
    public let invocation: AgentToolInvocation
    private let lock = NSLock()
    private var active = true
    private let onProgress: @Sendable (AgentToolProgress) -> Void

    public init(sessionID: String, invocation: AgentToolInvocation,
                onProgress: @escaping @Sendable (AgentToolProgress) -> Void = { _ in }) {
        self.sessionID = sessionID; self.invocation = invocation; self.onProgress = onProgress
    }

    public func progress(_ value: AgentToolProgress) {
        lock.withLock { if active { onProgress(value) } }
    }

    func finish() { lock.withLock { active = false } }
}

public enum AgentToolPolicyDecision: Sendable {
    case allow(JSONValue)
    case deny
}

public typealias AgentToolPolicy = @Sendable (AgentToolInvocation, JSONValue) async throws -> AgentToolPolicyDecision

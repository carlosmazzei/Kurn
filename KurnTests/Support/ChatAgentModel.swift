import AgentHarness
import Foundation
import KurnCore
import Synchronization

actor ChatAgentModel: AgentModel {
    enum Failure: Error { case provider, exhausted }
    let responses: [AgentTurnResponse]
    let pauseAt: Int?
    let appError: AppError?
    let fails: Bool
    private(set) var requests: [AgentTurnRequest] = []
    private(set) var wasCancelled = false

    init(_ responses: [AgentTurnResponse] = [], pauseAt: Int? = nil, appError: AppError? = nil, fails: Bool = false) {
        self.responses = responses
        self.pauseAt = pauseAt
        self.appError = appError
        self.fails = fails
    }

    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        let index = requests.count
        requests.append(request)
        if let appError { throw appError }
        if fails { throw Failure.provider }
        guard responses.indices.contains(index) else { throw Failure.exhausted }
        let response = responses[index]
        onEvent(.textDelta(response.text))
        if pauseAt == index {
            do { try await ChatAgentCancellationPause().wait() }
            catch { wasCancelled = true; throw error }
        }
        return response
    }
}

/// A paused provider must remain pending until the test's cancellation action.
/// A wall-clock sleep can expire while the general suite starves the main
/// actor, turning a cancellation/recovery test into an unrelated success.
final class ChatAgentCancellationPause: Sendable {
    private struct Storage {
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled = false
    }
    private let storage = Mutex(Storage())

    var hasWaiter: Bool { storage.withLock { $0.continuation != nil } }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = storage.withLock { value in
                    if value.cancelled { return true }
                    value.continuation = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let continuation = storage.withLock { value in
            value.cancelled = true
            let result = value.continuation
            value.continuation = nil
            return result
        }
        continuation?.resume(throwing: CancellationError())
    }
}

func chatAgentCall(_ name: String, arguments: JSONValue = .object([:]), id: String = UUID().uuidString) throws -> AgentToolCall {
    AgentToolCall(id: id, name: name, arguments: .null, rawArguments: try arguments.encodedString())
}

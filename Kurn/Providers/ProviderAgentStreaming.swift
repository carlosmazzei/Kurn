import AgentHarness
import Foundation
import KurnCore

extension LLMHTTP {
    /// Agent turns use the same bounded, origin-locked transport as streamed chat.
    static func streamAgent(
        _ request: URLRequest,
        session: URLSession,
        format: AgentWireFormat,
        identity: AgentRequestIdentity? = nil,
        onEvent: @escaping @Sendable (AgentModelEvent) -> Void
    ) async throws -> AgentTurnResponse {
        let accumulator = AgentWireAccumulator(format: format, requestID: identity?.id ?? UUID().uuidString)
        let retryAfter = RetryAfterBox()
        do {
            try await streamSSE(request, session: session, policy: .interactive(totalDeadline: chatTimeout),
                                onRetryAfter: { retryAfter.set($0) }) { payload in
                for event in try accumulator.consume(payload) { onEvent(event) }
            }
            try Task.checkCancellation()
            return try accumulator.response()
        } catch let error as AppError where error.isTransient && retryAfter.value != nil {
            // The session owns agent retries (`AgentRetryPolicy`); it waits as long as the provider
            // asked and sees only this `AppError` otherwise.
            throw AgentRetryAfter(error, seconds: retryAfter.value ?? 0)
        } catch let error as AgentWireError {
            switch error {
            case .remote(let message): throw AppError.apiError(statusCode: 0, message: message)
            case .invalidResponse, .bufferLimit, .deferred:
                throw AppError.decodingError(NSLocalizedString("error.provider_response_invalid", comment: "Invalid provider response"))
            case .emptyResponse: throw AppError.decodingError("empty agent response")
            case .incompleteToolCall: throw AppError.decodingError("incomplete agent tool call")
            case .incompleteStream: throw AppError.networkError(URLError(.networkConnectionLost))
            }
        }
    }
    static func agentStreamFailure(_ error: Error) -> AgentStreamFailure {
        if error is CancellationError { return .cancelled }
        if let app = error as? AppError {
            switch app {
            case .decodingError: return .invalidStream
            case .networkError(let urlError): return urlError.code == .cancelled ? .cancelled : .transport
            default: break
            }
        }
        return AgentStreamFailure.classify(error)
    }

}

/// The `Retry-After` of an agent request's rejected attempt, written by the transport's delegate.
private final class RetryAfterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval?
    var value: TimeInterval? { lock.withLock { seconds } }
    func set(_ value: TimeInterval) { lock.withLock { seconds = value } }
}

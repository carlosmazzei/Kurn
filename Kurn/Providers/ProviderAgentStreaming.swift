import AgentHarness
import Foundation
import KurnCore

extension LLMHTTP {
    /// Agent turns use the same bounded, origin-locked transport as streamed chat.
    static func streamAgent(
        _ request: URLRequest,
        session: URLSession,
        format: AgentWireFormat,
        onEvent: @escaping @Sendable (AgentModelEvent) -> Void
    ) async throws -> AgentTurnResponse {
        let accumulator = AgentWireAccumulator(format: format)
        do {
            try await streamSSE(request, session: session, policy: .interactive(totalDeadline: chatTimeout)) { payload in
                for event in try accumulator.consume(payload) { onEvent(event) }
            }
            try Task.checkCancellation()
            return try accumulator.response()
        } catch let error as AgentWireError {
            switch error {
            case .remote(let message): throw AppError.apiError(statusCode: 0, message: message)
            case .emptyResponse: throw AppError.decodingError("empty agent response")
            case .incompleteToolCall: throw AppError.decodingError("incomplete agent tool call")
            case .incompleteStream: throw AppError.networkError(URLError(.networkConnectionLost))
            }
        }
    }
}

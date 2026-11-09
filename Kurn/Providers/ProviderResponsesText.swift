import AgentHarness
import Foundation
import KurnCore

extension LLMHTTP {
    static func responsesTextData(_ data: Data) throws -> Data {
        do {
            return try OpenAIResponsesText.chatCompletionResponse(from: data)
        } catch let OpenAIResponsesTextError.remote(message) {
            throw AppError.apiError(statusCode: 0, message: message)
        } catch {
            throw AppError.decodingError(NSLocalizedString("error.provider_response_invalid", comment: "Invalid provider response"))
        }
    }

    static func streamResponsesText(
        _ request: URLRequest,
        session: URLSession,
        policy: HTTPPolicy,
        retriesBeforeFirstPayload: Bool = false,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> AgentTurnResponse {
        let accumulator = AgentWireAccumulator(format: .openAIResponses)
        do {
            try await streamSSE(request, session: session, policy: policy,
                                retriesBeforeFirstPayload: retriesBeforeFirstPayload) { payload in
                for event in try accumulator.consume(payload) {
                    if case .textDelta(let text) = event { onDelta(text) }
                }
            }
            try Task.checkCancellation()
            return try accumulator.response()
        } catch let error as AgentWireError {
            switch error {
            case .remote(let message): throw AppError.apiError(statusCode: 0, message: message)
            case .invalidResponse, .bufferLimit, .deferred:
                throw AppError.decodingError(NSLocalizedString("error.provider_response_invalid", comment: "Invalid provider response"))
            case .incompleteStream: throw AppError.networkError(URLError(.networkConnectionLost))
            case .emptyResponse:
                throw AppError.decodingError(NSLocalizedString("error.provider_response_empty", comment: "Empty provider response"))
            case .incompleteToolCall:
                throw AppError.decodingError(NSLocalizedString("error.provider_tool_call_incomplete", comment: "Incomplete tool call"))
            }
        }
    }
}

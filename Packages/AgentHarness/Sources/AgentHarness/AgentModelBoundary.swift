import Foundation

/// Covers request preparation too: every accepted provider call emits exactly one terminal event.
/// Transport helpers emit blocks; this boundary emits the authoritative message after trailing usage.
public enum AgentModelBoundary {
    public static func perform<Prepared: Sendable>(
        onEvent: @escaping @Sendable (AgentModelEvent) -> Void,
        classifyFailure: @Sendable (Error) -> AgentStreamFailure = { AgentStreamFailure.classify($0) },
        prepare: @Sendable () throws -> Prepared,
        stream: @Sendable (Prepared) async throws -> AgentTurnResponse
    ) async throws -> AgentTurnResponse {
        let prepared: Prepared
        do { try Task.checkCancellation(); prepared = try prepare() }
        catch { onEvent(.content(.failed(error is CancellationError ? .cancelled : .preparation))); throw error }
        do {
            let response = try await stream(prepared)
            try Task.checkCancellation()
            let message = try response.finalizedMessage()
            var validation = AgentMessageReducer()
            try validation.apply(.messageFinished(message))
            onEvent(.content(.messageFinished(message)))
            return AgentTurnResponse(text: response.text, usage: response.usage, stopReason: response.stopReason,
                providerMetadata: response.providerMetadata, discardedToolCalls: response.discardedToolCalls, message: message, blocksToolExecution: response.toolExecutionBlocked)
        } catch {
            onEvent(.content(.failed(classifyFailure(error))))
            throw error
        }
    }
}

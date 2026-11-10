import Foundation

extension AgentTurnResponse {
    func finalizedMessage() throws -> AgentContentMessage {
        if let message {
            guard message.role == .assistant else { throw AgentWireError.invalidResponse }
            if stopReason.permitsToolExecution {
                guard !message.hasIncompleteCalls, message.toolCalls.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
                      Set(message.toolCalls.map(\.id)).count == message.toolCalls.count else { throw AgentWireError.incompleteToolCall }
            }
            return message
        }
        var blocks: [AgentContentBlock] = text.isEmpty ? [] : [AgentContentBlock(id: "text", content: .text(text))]
        let calls = toolCalls + blockedToolCalls
        blocks += calls.enumerated().map { index, call in
            AgentContentBlock(id: "call\(index)", content: .toolCall(call, complete: stopReason != .maxTokens))
        }
        return try AgentContentMessage(id: UUID().uuidString, timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            role: .assistant, blocks: blocks, stopReason: stopReason, usage: usage, providerMetadata: providerMetadata)
    }

    func auditMessage() throws -> AgentMessage { .content(try finalizedMessage()) }

}

enum AgentResponseAudit {
    /// This is audit data, not tool execution. Successful recovery keeps it out of retry context.
    static func appendBlocked(_ response: AgentTurnResponse, state: inout AgentRunState,
                              events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                              trace: AgentTraceEmitter, toContext: Bool,
                              commit: @Sendable (AgentMessage) async throws -> Void,
                              syntheticReason: AgentToolBlockReason = .interruptedResponse,
                              content: String = "Tool not executed: the model response was interrupted or deferred.") async throws {
        for call in response.blockedToolCalls {
            guard let requestID = response.message?.identity?.requestID else { throw AgentWireError.invalidResponse }
            let invocation = try AgentMessageFactory.invocation(call, requestID: requestID)
            trace.beginInvocation(invocation)
            defer { trace.endInvocation() }
            state.requestedCalls += 1
            trace.record(.toolRequested, metrics: [.callOrdinal: state.requestedCalls, .toolCalls: state.toolCalls])
            trace.record(.toolSkipped, metrics: [.callOrdinal: state.requestedCalls, .isError: 1],
                         reason: response.stopReason == .maxTokens ? .outputLimit : nil)
            let reason: AgentToolBlockReason = response.stopReason == .maxTokens ? .outputLimit : syntheticReason
            let result = try AgentMessageFactory.result(invocation, output: AgentToolOutput(content: content, summary: content),
                                                        isError: true, syntheticReason: reason)
            try await commit(result)
            events.yield(.messageAppended(result))
            state.history.append(result)
            if toContext { state.context.append(result) }
            trace.record(.toolFinished, metrics: [.callOrdinal: state.requestedCalls, .isError: 1])
            events.yield(.toolFinished(callID: call.id, name: call.name, summary: content, isError: true))
        }
    }
}

extension AgentModelStopReason {
    var permitsToolExecution: Bool {
        switch self { case .endTurn, .toolUse: true; default: false }
    }
}

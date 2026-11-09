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

    func auditMessage() throws -> AgentMessage {
        if message != nil || !stopReason.permitsToolExecution || !blockedToolCalls.isEmpty { return .content(try finalizedMessage()) }
        return .assistant(text: text, toolCalls: toolCalls.map { call in
            AgentToolCall(id: call.id, name: call.name, arguments: (try? JSONValue.parse(call.rawArguments)) ?? .null,
                          rawArguments: call.rawArguments, providerMetadata: call.providerMetadata)
        }, providerMetadata: providerMetadata)
    }
}

enum AgentResponseAudit {
    /// This is audit data, not tool execution. Successful recovery keeps it out of retry context.
    static func appendBlocked(_ response: AgentTurnResponse, state: inout AgentRunState,
                              events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                              trace: AgentTraceEmitter, toContext: Bool,
                              content: String = "Tool not executed: the model response was interrupted or deferred.") {
        for call in response.blockedToolCalls {
            state.requestedCalls += 1
            trace.record(.toolRequested, metrics: [.callOrdinal: state.requestedCalls, .toolCalls: state.toolCalls])
            trace.record(.toolSkipped, metrics: [.callOrdinal: state.requestedCalls, .isError: 1],
                         reason: response.stopReason == .maxTokens ? .outputLimit : nil)
            let result = AgentMessage.toolResult(callID: call.id, toolName: call.name, content: content, isError: true)
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

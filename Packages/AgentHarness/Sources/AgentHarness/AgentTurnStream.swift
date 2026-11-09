import Foundation

/// Fences late callbacks and closes a request once. The return value is authoritative, and
/// invocation identity is assigned by the owner before publishing or executing the final message.
final class AgentTurnStream: @unchecked Sendable {
    private let lock = NSLock()
    private let events: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let trace: AgentTraceEmitter
    private let forwardsText: Bool
    private let request: AgentRequestIdentity
    private let descriptor: AgentModelDescriptor?
    private var terminal: AgentContentEvent?
    private var partial = AgentMessageReducer()
    private var legacyText = ""
    private var visible = false
    private var finalPublished = false
    private var failureSnapshot: AgentContentMessage?

    init(events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter,
         request: AgentRequestIdentity, descriptor: AgentModelDescriptor?, forwardsText: Bool = true) {
        self.events = events; self.trace = trace; self.request = request; self.descriptor = descriptor; self.forwardsText = forwardsText
    }

    var hasVisibleText: Bool { lock.withLock { visible } }
    var failureMessage: AgentContentMessage? { lock.withLock { failureSnapshot } }
    var failureCode: Int {
        lock.withLock {
            guard case .failed(let failure) = terminal else { return 0 }
            return failure.diagnosticCode
        }
    }

    func consume(_ event: AgentModelEvent) {
        lock.withLock {
            guard terminal == nil else { return }
            switch event {
            case .textDelta(let text):
                if !text.isEmpty {
                    guard legacyText.utf8.count + text.utf8.count <= 8 * 1_024 * 1_024 else { failLocked(.invalidStream); return }
                    legacyText += text; visible = true
                    if forwardsText { events.yield(.textDelta(text)) }
                }
            case .replayAdjusted(let adjustment): trace.record(.replayPrepared, metrics: adjustment.diagnosticMetrics)
            case .outputBudgetAdjusted(let requested, let sent):
                trace.record(.outputBudgetAdjusted, metrics: [.maxOutputTokens: requested, .sentMaxOutputTokens: sent])
            case .content(let content):
                switch content {
                case .messageFinished: terminal = content // Published only after the method returns and validation succeeds.
                case .failed(let failure): failLocked(failure)
                default:
                    do { try partial.apply(content); events.yield(.modelContent(content)) }
                    catch { failLocked(.invalidStream) }
                }
            }
        }
    }

    func complete(_ response: AgentTurnResponse) throws -> AgentTurnResponse {
        try lock.withLock {
            if case .failed(let failure) = terminal {
                if failure == .cancelled { throw CancellationError() }
                throw AgentWireError.invalidResponse
            }
            let provider = try response.finalizedMessage()
            if case .messageFinished(let observed) = terminal, observed != provider { throw AgentWireError.invalidResponse }
            let message = try AgentMessageFactory.assistant(provider, request: request, descriptor: descriptor)
            var validation = AgentMessageReducer()
            try validation.apply(.messageFinished(message))
            terminal = .messageFinished(message)
            events.yield(.modelContent(.messageFinished(message)))
            finalPublished = true
            return AgentTurnResponse(text: message.text, usage: response.usage, stopReason: response.stopReason,
                providerMetadata: response.providerMetadata, discardedToolCalls: response.discardedToolCalls,
                message: message, blocksToolExecution: response.toolExecutionBlocked)
        }
    }

    func fail(_ error: Error) {
        lock.withLock {
            if finalPublished {
                if case .messageFinished(let accepted) = terminal { failureSnapshot = accepted }
                return
            }
            let failure: AgentStreamFailure
            if case .failed(let observed) = terminal { failure = observed }
            else { failure = AgentStreamFailure.classify(error) }
            if terminal == nil || failureSnapshot == nil {
                // A conflicting provider final is not an accepted canonical final.
                if case .messageFinished = terminal { terminal = nil }
                if terminal == nil { failLocked(failure) }
                var blocks = partial.blocks
                if blocks.isEmpty, !legacyText.isEmpty { blocks = [AgentContentBlock(id: "text", content: .text(legacyText))] }
                failureSnapshot = try? AgentMessageFactory.failure(failure, blocks: blocks, request: request, descriptor: descriptor)
                if failureSnapshot == nil {
                    trace.record(.payloadClipped, metrics: [.omittedItems: blocks.count])
                    failureSnapshot = try? AgentMessageFactory.failure(failure, blocks: [], request: request, descriptor: nil)
                }
            }
        }
    }

    private func failLocked(_ failure: AgentStreamFailure) {
        guard terminal == nil else { return }
        terminal = .failed(failure)
        events.yield(.modelContent(.failed(failure)))
    }
}

extension AgentStreamFailure {
    var diagnosticCode: Int {
        switch self { case .preparation: 1; case .transport: 2; case .invalidStream: 3; case .cancelled: 4; case .deferred: 5 }
    }

    public static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let wire = error as? AgentWireError {
            switch wire { case .remote: return .transport; case .deferred: return .deferred; default: return .invalidStream }
        }
        return error is AgentContentError ? .invalidStream : .transport
    }
}

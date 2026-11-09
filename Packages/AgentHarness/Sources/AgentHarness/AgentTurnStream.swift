import Foundation

/// Fences late callbacks and closes a request once, including failures before the first block.
final class AgentTurnStream: @unchecked Sendable {
    private let lock = NSLock()
    private let events: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let trace: AgentTraceEmitter
    private let forwardsText: Bool
    private var terminal: AgentContentEvent?
    private var visible = false

    init(events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter, forwardsText: Bool = true) {
        self.events = events
        self.trace = trace
        self.forwardsText = forwardsText
    }

    var hasVisibleText: Bool { lock.withLock { visible } }

    var failureCode: Int {
        lock.withLock {
            guard case .failed(let failure) = terminal else { return 0 }
            switch failure { case .preparation: return 1; case .transport: return 2; case .invalidStream: return 3; case .cancelled: return 4; case .deferred: return 5 }
        }
    }

    func consume(_ event: AgentModelEvent) {
        lock.withLock {
            guard terminal == nil else { return }
            switch event {
            case .textDelta(let text):
                if !text.isEmpty {
                    visible = true
                    if forwardsText { events.yield(.textDelta(text)) }
                }
            case .replayAdjusted(let adjustment): trace.record(.replayPrepared, metrics: adjustment.diagnosticMetrics)
            case .outputBudgetAdjusted(let requested, let sent):
                trace.record(.outputBudgetAdjusted, metrics: [.maxOutputTokens: requested, .sentMaxOutputTokens: sent])
            case .content(let content):
                if case .messageFinished = content { terminal = content }
                if case .failed = content { terminal = content }
                events.yield(.modelContent(content))
            }
        }
    }

    func complete(_ response: AgentTurnResponse) throws {
        try lock.withLock {
            if case .failed(let failure) = terminal {
                if failure == .cancelled { throw CancellationError() }
                throw AgentWireError.invalidResponse
            }
            let message = try response.finalizedMessage()
            var validation = AgentMessageReducer()
            try validation.apply(.messageFinished(message))
            if case .messageFinished(let observed) = terminal {
                guard observed == message else { throw AgentWireError.invalidResponse }
            } else {
                terminal = .messageFinished(message)
                events.yield(.modelContent(.messageFinished(message)))
            }
        }
    }

    func fail(_ error: Error) {
        lock.withLock {
            guard terminal == nil else { return }
            let failure: AgentStreamFailure
            if error is CancellationError { failure = .cancelled }
            else if let wire = error as? AgentWireError {
                switch wire { case .remote: failure = .transport; case .deferred: failure = .deferred; default: failure = .invalidStream }
            } else { failure = error is AgentContentError ? .invalidStream : .transport }
            terminal = .failed(failure)
            events.yield(.modelContent(.failed(failure)))
        }
    }
}

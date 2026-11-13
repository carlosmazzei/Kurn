import Foundation

/// Provider-neutral agent loop with ordered tool results. Tool failures are conversation data.
public struct NativeHarness: Sendable {
    let model: any AgentModel
    let limits: AgentLimits
    /// Prices a request's reported usage in USD; nil for a usage it cannot price (NH07).
    let costEstimator: (@Sendable (AgentUsage) -> Double?)?
    let compactor: AgentContextCompactor
    let confirm: @Sendable (AgentToolCall) async -> Bool
    let toolPolicy: AgentToolPolicy
    let maxParallelReads: Int
    let isContextOverflow: @Sendable (Error) -> Bool
    let retryPolicy: AgentRetryPolicy
    var messageCommit: @Sendable (AgentMessage) async throws -> Void = { _ in }
    var usageCommit: @Sendable (AgentUsage) async throws -> Void = { _ in }
    var compactionCommit: @Sendable (AgentCompactionCheckpoint) async throws -> Void = { _ in }
    var inputQueue: AgentInputQueue?
    private let diagnosticSink: @Sendable (AgentDiagnostic) -> Void

    /// Appended to the system prompt for the tool-less wrap-up turn after a turn or tool-call limit.
    public static let wrapUpInstruction = """
        The tool budget for this answer is exhausted. Do not call any tools. Answer now using only the \
        information already gathered above, and say briefly which parts could not be checked.
        """

    /// - Parameter isContextOverflow: recognizes a provider rejecting a request as too long; the
    ///   harness then compacts and retries that turn once.
    public init(model: any AgentModel, limits: AgentLimits = AgentLimits(),
                costEstimator: (@Sendable (AgentUsage) -> Double?)? = nil,
                contextPolicy: AgentContextPolicy = AgentContextPolicy(contextWindow: 128_000),
                tokenEstimator: @escaping @Sendable (String) -> Int = { TokenEstimate.tokens(in: $0) },
                isContextOverflow: @escaping @Sendable (Error) -> Bool = {
                    ($0 as? any AgentContextOverflowError)?.isContextOverflow == true
                },
                maxParallelReads: Int = 4,
                retryPolicy: AgentRetryPolicy = .none,
                toolPolicy: @escaping AgentToolPolicy = { _, arguments in .allow(arguments) },
                confirm: @escaping @Sendable (AgentToolCall) async -> Bool = { _ in false },
                diagnosticSink: @escaping @Sendable (AgentDiagnostic) -> Void = { _ in }) {
        self.model = model
        self.limits = limits
        self.costEstimator = costEstimator
        self.compactor = AgentContextCompactor(policy: contextPolicy, tokenEstimator: tokenEstimator)
        self.isContextOverflow = isContextOverflow
        self.retryPolicy = retryPolicy
        self.confirm = confirm
        self.toolPolicy = toolPolicy
        self.maxParallelReads = min(16, max(1, maxParallelReads))
        self.diagnosticSink = diagnosticSink
    }

    /// Fit the desired output capacity to the actual context before every request, as pi does.
    public func run(systemPrompt: String, history: [AgentMessage], prompt: String,
                    tools: [AgentTool], maxOutputTokens: Int? = nil,
                    contextResolution: AgentContextResolution? = nil, context: AgentRunContext = AgentRunContext()) -> AsyncThrowingStream<AgentEvent, Error> {
        launch(systemPrompt: systemPrompt, history: history, prompt: prompt, tools: tools,
               maxOutputTokens: maxOutputTokens, contextResolution: contextResolution, context: context,
               observation: .legacy).events
    }

    /// An owned run. Canonical writes use an awaited channel. Detaching an observer does not
    /// cancel execution. The owner must cancel explicitly and await `result()` before reporting
    /// termination. `.bounded` observation keeps the newest 128 events; `.complete` keeps every
    /// event for a host whose presentation reducer cannot tolerate a gap (it is not a canonical
    /// channel either — the message/usage sinks are).
    public func start(systemPrompt: String, history: [AgentMessage], prompt: String,
                      tools: [AgentTool], maxOutputTokens: Int? = nil,
                      contextResolution: AgentContextResolution? = nil,
                      context: AgentRunContext = AgentRunContext(),
                      observation: AgentRunObservation = .bounded) -> AgentRunHandle {
        launch(systemPrompt: systemPrompt, history: history, prompt: prompt, tools: tools,
               maxOutputTokens: maxOutputTokens, contextResolution: contextResolution, context: context,
               observation: observation == .bounded ? .owned : .ownedComplete)
    }

    /// The sink must commit or throw. It is called in canonical order, including failure audit,
    /// before dependent tool/model work and before message-appended observations.
    public func persistingMessages(_ commit: @escaping @Sendable (AgentMessage) async throws -> Void) -> Self {
        var copy = self
        copy.messageCommit = commit
        return copy
    }

    public func persistingUsage(_ commit: @escaping @Sendable (AgentUsage) async throws -> Void) -> Self {
        var copy = self
        copy.usageCommit = commit
        return copy
    }

    /// Drains `queue` at the run's boundaries (NH08): steering after each complete tool batch and
    /// before the run would finish, follow-ups only once no tool call and no steering is left.
    /// Each drained item is committed as a user message (its ID is the item's) before the next
    /// request. A run that stops for a limit, a failure or a cancel leaves the rest queued.
    public func receivingInput(_ queue: AgentInputQueue) -> Self {
        var copy = self
        copy.inputQueue = queue
        return copy
    }

    /// Called with each summary compaction before any request uses the compacted context. A
    /// throw fails the run: no request runs on context the log does not have.
    public func persistingCompaction(_ commit: @escaping @Sendable (AgentCompactionCheckpoint) async throws -> Void) -> Self {
        var copy = self
        copy.compactionCommit = commit
        return copy
    }

    private enum ObservationMode { case legacy, owned, ownedComplete }

    /// Continues a run from `history` without a new prompt (NH08). When the history ends on a
    /// request or a tool result, the next request answers it. When it ends on an assistant reply,
    /// one selection of queued input — steering, else follow-ups — is taken in first, by each
    /// queue's mode; with nothing queued, or an empty history, the run fails with
    /// `AgentContinueError.nothingToContinue` before any request and leaves the queues untouched.
    public func continueRun(systemPrompt: String, history: [AgentMessage], tools: [AgentTool],
                            maxOutputTokens: Int? = nil, contextResolution: AgentContextResolution? = nil,
                            context: AgentRunContext = AgentRunContext(),
                            observation: AgentRunObservation = .bounded) -> AgentRunHandle {
        launch(systemPrompt: systemPrompt, history: history, prompt: nil, tools: tools,
               maxOutputTokens: maxOutputTokens, contextResolution: contextResolution, context: context,
               observation: observation == .bounded ? .owned : .ownedComplete)
    }

    private func launch(systemPrompt: String, history: [AgentMessage], prompt: String?, tools: [AgentTool],
                        maxOutputTokens: Int?, contextResolution: AgentContextResolution?, context: AgentRunContext,
                        observation: ObservationMode) -> AgentRunHandle {
        let (events, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream(
            bufferingPolicy: observation == .owned ? .bufferingNewest(128) : .unbounded)
        let trace = AgentTraceEmitter(events: continuation, resolutionID: contextResolution?.id, sink: diagnosticSink, context: context)
        let task = Task {
            do {
                continuation.yield(.runStarted)
                if let contextResolution { continuation.yield(.contextResolved(contextResolution)) }
                trace.record(.runStarted, metrics: limits.diagnosticMetrics)
                let outcome = try await drive(systemPrompt: systemPrompt, history: history, prompt: prompt,
                    tools: tools, maxOutputTokens: maxOutputTokens, events: continuation, trace: trace)
                continuation.finish()
                return outcome
            } catch {
                trace.record(error is CancellationError ? .runCancelled : .runFailed)
                continuation.finish(throwing: error)
                throw error
            }
        }
        if observation == .legacy { continuation.onTermination = { _ in task.cancel() } }
        return AgentRunHandle(events: events, task: task)
    }

    func publish(_ message: AgentMessage, events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        try await messageCommit(message)
        events.yield(.messageAppended(message))
    }

    struct TurnSettings {
        let systemPrompt: String
        let tools: [AgentToolSpec]
        var outputBudget: AgentOutputBudget
        var maxOutputTokens: Int { outputBudget.tokens }
        var allowsToolCalls = true
    }

    struct NormalizedToolCall {
        let call: AgentToolCall
        let hasValidArguments: Bool

        init(_ original: AgentToolCall) {
            let arguments = try? JSONValue.parse(original.rawArguments)
            var call = original
            call.arguments = arguments ?? .null
            self.call = call
            hasValidArguments = original.hasValidArguments
        }
    }

    private func drive(systemPrompt: String, history: [AgentMessage], prompt: String?, tools: [AgentTool],
                       maxOutputTokens: Int?, events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                       trace: AgentTraceEmitter) async throws -> AgentRunOutcome {
        do { _ = try AgentToolRegistry(tools) }
        catch { trace.record(.toolRegistryRejected); throw error }
        var messages = history
        if let prompt {
            let user = try AgentMessageFactory.user(prompt)
            try await publish(user, events: events)
            messages.append(user)
        }
        var state = AgentRunState(history: messages, context: messages)
        if prompt == nil { try await prepareContinuation(&state, events: events, trace: trace) }
        state.allowedTurns = limits.maxTurns
        state.allowedToolCalls = limits.maxToolCalls
        let specs = tools.map(\.spec)
        var reason = AgentRunStopReason.turnLimit
        var settings = TurnSettings(systemPrompt: systemPrompt, tools: specs,
                                    outputBudget: AgentOutputBudget(requested: maxOutputTokens, policy: compactor.policy))
        while true {
            try Task.checkCancellation()
            if costLimitReached(state) { reason = .costLimit; break }
            if state.turns >= state.allowedTurns,
               !state.extendBudget(.turnLimit, limits: limits, trace: trace) { reason = .turnLimit; break }
            guard let response = try await modelTurn(&settings, state: &state, events: events, trace: trace) else {
                reason = .costLimit
                break
            }
            state.finalText = response.text
            let calls = response.stopReason == .maxTokens ? [] : response.toolCalls.map(NormalizedToolCall.init)
            if !state.responseAlreadyAudited {
                let assistant = try response.auditMessage()
                try await publish(assistant, events: events)
                state.history.append(assistant)
                state.context.append(assistant)
                try await AgentResponseAudit.appendBlocked(response, state: &state, events: events, trace: trace, toContext: true, commit: messageCommit)
            }
            if response.stopReason == .deferred { throw AgentWireError.deferred }
            if response.stopReason == .aborted { throw CancellationError() }
            if response.stopReason == .error || (response.stopReason != .maxTokens && !response.blockedToolCalls.isEmpty) {
                throw AgentWireError.invalidResponse
            }
            if response.stopReason == .maxTokens {
                reason = .outputLimit
                break
            }
            if calls.isEmpty {
                // Queued input continues the run: steering first, then one follow-up selection.
                if try await injectQueued(.steering, state: &state, events: events, trace: trace) { continue }
                if try await injectQueued(.followUp, state: &state, events: events, trace: trace) { continue }
                reason = costLimitReached(state) ? .costLimit : .completed
                break
            }
            let stop = try await execute(calls, requestID: response.message?.identity?.requestID, tools: tools, state: &state, events: events, trace: trace)
            if let stop { reason = stop; break }
            // Steering enters after the whole tool batch, before the next request.
            _ = try await injectQueued(.steering, state: &state, events: events, trace: trace)
        }
        if reason != .completed { recordLimit(reason, state: &state, trace: trace) }
        try Task.checkCancellation()
        if limits.wrapUpOnLimit, reason == .turnLimit || reason == .toolCallLimit,
           case .toolResult? = state.context.last?.legacyProjection, !costLimitReached(state),
           try await wrapUp(settings, state: &state, events: events, trace: trace) == .maxTokens {
            reason = .outputLimit
        }
        try Task.checkCancellation()
        trace.record(.runFinished, metrics: [.toolCalls: state.toolCalls, .inputTokens: state.usage.inputTokens,
                                            .outputTokens: state.usage.outputTokens,
                                            .blockedCalls: state.requestedCalls - state.toolCalls], reason: reason)
        let outcome = AgentRunOutcome(messages: state.history, finalText: state.finalText,
                                      stopReason: reason, totalUsage: state.usage,
                                      estimatedCostUSD: costEstimator != nil && state.costKnown ? state.cost : nil)
        events.yield(.runFinished(outcome))
        return outcome
    }

    /// What `continueRun` answers: the history's open request or tool result, or else one queued
    /// selection after a finished assistant reply. Nothing to answer fails before any request.
    private func prepareContinuation(_ state: inout AgentRunState,
                                     events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                                     trace: AgentTraceEmitter) async throws {
        guard let last = state.context.last else { throw AgentContinueError.nothingToContinue }
        let endsOnReply: Bool
        switch last {
        case .content(let message): endsOnReply = message.role == .assistant
        case .assistant: endsOnReply = true
        case .tool, .toolResult, .user: endsOnReply = false
        }
        guard endsOnReply else { return }
        if try await injectQueued(.steering, state: &state, events: events, trace: trace) { return }
        if try await injectQueued(.followUp, state: &state, events: events, trace: trace) { return }
        throw AgentContinueError.nothingToContinue
    }

    /// Drains `kind` from the input queue and commits each item as a user message. Returns whether
    /// anything was injected.
    private func injectQueued(_ kind: AgentInputQueue.Kind, state: inout AgentRunState,
                              events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                              trace: AgentTraceEmitter) async throws -> Bool {
        guard let inputQueue else { return false }
        try Task.checkCancellation()
        let items = try await inputQueue.drain(kind)
        guard !items.isEmpty else { return false }
        trace.record(.queuedInputDrained, metrics: [.queuedItems: items.count, .queueKind: kind == .steering ? 0 : 1])
        for item in items {
            let message = try AgentMessageFactory.user(item.text, id: item.id)
            try await publish(message, events: events)
            state.history.append(message)
            state.context.append(message)
        }
        return true
    }

    /// One text-only answer from what the run already gathered, instead of ending on tool results.
    /// Tools stay declared (some vendors reject tool history without them) but tool choice is "none";
    /// calls a vendor returns anyway are dropped. A reply without text is left as no answer, so the
    /// limit stays visible with an empty answer. Returns the wrap-up turn's stop reason.
    private func wrapUp(_ settings: TurnSettings, state: inout AgentRunState,
                        events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                        trace: AgentTraceEmitter) async throws -> AgentModelStopReason? {
        trace.record(.wrapUpStarted)
        var wrapUp = TurnSettings(systemPrompt: settings.systemPrompt + "\n\n" + Self.wrapUpInstruction,
                                  tools: settings.tools, outputBudget: settings.outputBudget, allowsToolCalls: false)
        guard let response = try await modelTurn(&wrapUp, state: &state, events: events, trace: trace) else { return nil }
        try Task.checkCancellation()
        state.finalText = response.text
        if !state.responseAlreadyAudited {
            let blocked = AgentTurnResponse(text: response.text, toolCalls: response.toolCalls + response.blockedToolCalls,
                usage: response.usage, stopReason: response.stopReason, providerMetadata: response.providerMetadata,
                message: response.message, blocksToolExecution: true)
            let assistant = try blocked.auditMessage()
            try await publish(assistant, events: events)
            state.history.append(assistant)
            state.context.append(assistant)
            try await AgentResponseAudit.appendBlocked(blocked, state: &state, events: events, trace: trace, toContext: true, commit: messageCommit, syntheticReason: .toolsDisabled,
                content: "Tool not executed: tool calling was disabled for this request.")
        }
        if response.stopReason == .deferred { throw AgentWireError.deferred }
        if response.stopReason == .aborted { throw CancellationError() }
        if response.stopReason == .error { throw AgentWireError.invalidResponse }
        trace.record(.wrapUpFinished, reason: response.stopReason == .maxTokens ? .outputLimit : nil)
        return response.stopReason
    }

}

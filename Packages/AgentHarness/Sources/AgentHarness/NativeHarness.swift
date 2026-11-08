import Foundation

/// Sequential provider-neutral agent loop. Tool failures are conversation data.
public struct NativeHarness: Sendable {
    private let model: any AgentModel
    private let limits: AgentLimits
    private let costEstimator: (@Sendable (AgentUsage) -> Double)?
    private let compactor: AgentContextCompactor
    private let confirm: @Sendable (AgentToolCall) async -> Bool
    private let isContextOverflow: @Sendable (Error) -> Bool
    private let diagnosticSink: @Sendable (AgentDiagnostic) -> Void

    /// Appended to the system prompt for the tool-less wrap-up turn after a turn or tool-call limit.
    public static let wrapUpInstruction = """
        The tool budget for this answer is exhausted. Do not call any tools. Answer now using only the \
        information already gathered above, and say briefly which parts could not be checked.
        """

    /// - Parameter isContextOverflow: recognizes a provider rejecting a request as too long; the
    ///   harness then compacts and retries that turn once.
    public init(model: any AgentModel, limits: AgentLimits = AgentLimits(),
                costEstimator: (@Sendable (AgentUsage) -> Double)? = nil,
                contextPolicy: AgentContextPolicy = AgentContextPolicy(contextWindow: 128_000),
                tokenEstimator: @escaping @Sendable (String) -> Int = { TokenEstimate.tokens(in: $0) },
                isContextOverflow: @escaping @Sendable (Error) -> Bool = {
                    ($0 as? any AgentContextOverflowError)?.isContextOverflow == true
                },
                confirm: @escaping @Sendable (AgentToolCall) async -> Bool = { _ in false },
                diagnosticSink: @escaping @Sendable (AgentDiagnostic) -> Void = { _ in }) {
        self.model = model
        self.limits = limits
        self.costEstimator = costEstimator
        self.compactor = AgentContextCompactor(policy: contextPolicy, tokenEstimator: tokenEstimator)
        self.isContextOverflow = isContextOverflow
        self.confirm = confirm
        self.diagnosticSink = diagnosticSink
    }

    public func run(systemPrompt: String, history: [AgentMessage], prompt: String,
                    tools: [AgentTool], maxOutputTokens: Int,
                    contextResolution: AgentContextResolution? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let trace = AgentTraceEmitter(events: continuation, resolutionID: contextResolution?.id, sink: diagnosticSink)
            let task = Task {
                do {
                    continuation.yield(.runStarted)
                    if let contextResolution { continuation.yield(.contextResolved(contextResolution)) }
                    trace.record(.runStarted, metrics: [.maxTurns: limits.maxTurns, .maxToolCalls: limits.maxToolCalls])
                    try await drive(systemPrompt: systemPrompt, history: history, prompt: prompt,
                                    tools: tools, maxOutputTokens: maxOutputTokens, events: continuation, trace: trace)
                    continuation.finish()
                } catch {
                    trace.record(error is CancellationError ? .runCancelled : .runFailed)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct RunState {
        var history: [AgentMessage]
        var context: [AgentMessage]
        var usage = AgentUsage()
        var cost = 0.0
        var toolCalls = 0
        var requestedCalls = 0
        var turns = 0
        var finalText = ""
        var firstLimit: AgentRunStopReason?
        /// Tokens the provider reported for the latest turn (its input plus its reply) and the
        /// context length once that reply was appended. Later messages are estimated on top of it;
        /// a compaction clears it, since the reported size no longer describes the context.
        var usageAnchor: (tokens: Int, contextCount: Int)?
    }

    private struct TurnSettings {
        let systemPrompt: String
        let tools: [AgentToolSpec]
        let maxOutputTokens: Int
        var allowsToolCalls = true
    }

    /// Set from the synchronous stream callback; read after the turn to decide whether a retry is safe.
    private final class StreamFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var streamed = false
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return streamed
        }

        func set() {
            lock.lock()
            streamed = true
            lock.unlock()
        }
    }

    private struct NormalizedToolCall {
        let call: AgentToolCall
        let hasValidArguments: Bool

        init(_ original: AgentToolCall) {
            let arguments = try? JSONValue.parse(original.rawArguments)
            var call = original
            call.arguments = arguments ?? .null
            self.call = call
            hasValidArguments = arguments != nil
        }
    }

    private func drive(systemPrompt: String, history: [AgentMessage], prompt: String, tools: [AgentTool],
                       maxOutputTokens: Int, events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                       trace: AgentTraceEmitter) async throws {
        let messages = history + [.user(prompt)]
        var state = RunState(history: messages, context: messages)
        let specs = tools.map(\.spec)
        var reason = AgentRunStopReason.turnLimit
        let settings = TurnSettings(systemPrompt: systemPrompt, tools: specs, maxOutputTokens: maxOutputTokens)
        for _ in 0..<limits.maxTurns {
            try Task.checkCancellation()
            if costLimitReached(state) { reason = .costLimit; break }
            guard let response = try await modelTurn(settings, state: &state, events: events, trace: trace) else {
                reason = .costLimit
                break
            }
            state.finalText = response.text
            let calls = response.stopReason == .maxTokens ? [] : response.toolCalls.map(NormalizedToolCall.init)
            let assistant = AgentMessage.assistant(text: response.text, toolCalls: calls.map(\.call),
                                                   providerMetadata: response.providerMetadata)
            state.history.append(assistant)
            state.context.append(assistant)
            if response.stopReason == .maxTokens {
                reason = .outputLimit
                break
            }
            if calls.isEmpty {
                reason = costLimitReached(state) ? .costLimit : .completed
                break
            }
            let stop = try await execute(calls, tools: tools, state: &state, events: events, trace: trace)
            if let stop { reason = stop; break }
        }
        if reason != .completed { recordLimit(reason, state: &state, trace: trace) }
        try Task.checkCancellation()
        if limits.wrapUpOnLimit, reason == .turnLimit || reason == .toolCallLimit,
           case .toolResult? = state.context.last, !costLimitReached(state),
           try await wrapUp(settings, state: &state, events: events, trace: trace) == .maxTokens {
            reason = .outputLimit
        }
        try Task.checkCancellation()
        trace.record(.runFinished, metrics: [.toolCalls: state.toolCalls, .inputTokens: state.usage.inputTokens,
                                            .outputTokens: state.usage.outputTokens,
                                            .blockedCalls: state.requestedCalls - state.toolCalls], reason: reason)
        events.yield(.runFinished(AgentRunOutcome(messages: state.history, finalText: state.finalText,
                                                 stopReason: reason, totalUsage: state.usage)))
    }

    /// One text-only answer from what the run already gathered, instead of ending on tool results.
    /// Tools stay declared (some vendors reject tool history without them) but tool choice is "none";
    /// calls a vendor returns anyway are dropped. A reply without text is left as no answer, so the
    /// limit stays visible with an empty answer. Returns the wrap-up turn's stop reason.
    private func wrapUp(_ settings: TurnSettings, state: inout RunState,
                        events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                        trace: AgentTraceEmitter) async throws -> AgentModelStopReason? {
        trace.record(.wrapUpStarted)
        let wrapUp = TurnSettings(systemPrompt: settings.systemPrompt + "\n\n" + Self.wrapUpInstruction,
                                  tools: settings.tools, maxOutputTokens: settings.maxOutputTokens, allowsToolCalls: false)
        guard let response = try await modelTurn(wrapUp, state: &state, events: events, trace: trace) else { return nil }
        try Task.checkCancellation()
        state.finalText = response.text
        if !response.text.isEmpty {
            let assistant = AgentMessage.assistant(text: response.text, toolCalls: [])
            state.history.append(assistant)
            state.context.append(assistant)
        }
        trace.record(.wrapUpFinished, reason: response.stopReason == .maxTokens ? .outputLimit : nil)
        return response.stopReason
    }

    /// Compacts when the context outgrows the window, streams one turn and anchors the context size
    /// to the usage it reports. A context-overflow rejection compacts and retries once, provided
    /// nothing was streamed yet and compaction actually shrank the context. Returns nil when a
    /// compaction summary exhausted the cost limit before the turn could be sent.
    private func modelTurn(_ settings: TurnSettings, state: inout RunState,
                           events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                           trace: AgentTraceEmitter) async throws -> AgentTurnResponse? {
        events.yield(.turnStarted(index: state.turns))
        state.turns += 1
        try await compact(settings, state: &state, events: events, trace: trace)
        var retried = false
        while true {
            if costLimitReached(state) { return nil }
            let streamed = StreamFlag()
            let started = ContinuousClock.now
            trace.record(.requestStarted, metrics: [.turnIndex: state.turns - 1, .messageCount: state.context.count,
                                                   .toolCount: settings.tools.count, .maxOutputTokens: settings.maxOutputTokens])
            do {
                let response = try await model.streamTurn(
                    AgentTurnRequest(systemPrompt: settings.systemPrompt, messages: state.context,
                                     tools: settings.tools, maxOutputTokens: settings.maxOutputTokens,
                                     allowsToolCalls: settings.allowsToolCalls)
                ) { event in
                    if case .textDelta(let text) = event {
                        streamed.set()
                        events.yield(.textDelta(text))
                    }
                }
                try Task.checkCancellation()
                trace.record(.requestFinished, metrics: [.durationMs: Self.milliseconds(since: started)])
                record(response.usage, state: &state, events: events)
                if let usage = response.usage, usage.inputTokens > 0 {
                    // The caller appends this reply, so the anchor covers one more message.
                    state.usageAnchor = (usage.inputTokens + usage.outputTokens, state.context.count + 1)
                }
                return response
            } catch {
                trace.record(.requestFailed, metrics: [.durationMs: Self.milliseconds(since: started)])
                try Task.checkCancellation()
                guard !retried, !streamed.value, isContextOverflow(error) else { throw error }
                retried = true
                let previous = state.context
                try await compact(settings, state: &state, events: events, trace: trace, force: true)
                guard state.context != previous else { throw error }
            }
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let parts = start.duration(to: .now).components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    private func recordLimit(_ reason: AgentRunStopReason, state: inout RunState, trace: AgentTraceEmitter) {
        guard state.firstLimit == nil else { return }
        state.firstLimit = reason
        trace.record(.limitReached, metrics: [.toolCalls: state.toolCalls, .maxToolCalls: limits.maxToolCalls,
                                             .turnIndex: state.turns, .maxTurns: limits.maxTurns], reason: reason)
    }

    private func costLimitReached(_ state: RunState) -> Bool {
        limits.maxCostUSD.map { state.cost >= $0 } ?? false
    }

    private func record(_ usage: AgentUsage?, state: inout RunState,
                        events: AsyncThrowingStream<AgentEvent, Error>.Continuation) {
        guard let usage else { return }
        state.usage = state.usage.adding(usage)
        state.cost += max(0, costEstimator?(usage) ?? 0)
        events.yield(.usage(usage))
    }

    /// The context size of the next request: the provider-reported size of the latest turn plus
    /// estimates of the messages appended since, or a full estimate before any usage is known.
    private func contextTokens(_ settings: TurnSettings, state: RunState) -> Int {
        if let anchor = state.usageAnchor, anchor.contextCount <= state.context.count {
            return anchor.tokens + compactor.estimateTokens(of: state.context[anchor.contextCount...])
        }
        return compactor.estimateTokens(systemPrompt: settings.systemPrompt, messages: state.context,
                                        tools: settings.tools)
    }

    /// Compacts once the context exceeds the window minus the reserve, or unconditionally (`force`)
    /// after a provider rejected the request as too long. Older messages are replaced by a summary
    /// and the newest `keepRecentTokens` are kept. A summary cut off by the output limit is not
    /// used; when compaction was forced, or the summary request itself overflows, the older part
    /// is replaced by a fixed omission note instead, so recovery never stalls.
    private func compact(_ settings: TurnSettings, state: inout RunState,
                         events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter,
                         force: Bool = false) async throws {
        let before = contextTokens(settings, state: state)
        trace.record(.contextCheck, metrics: [.contextTokens: before, .thresholdTokens: compactor.policy.compactionThreshold,
                                             .retainedTokens: compactor.policy.effectiveKeepRecentTokens, .forced: force ? 1 : 0])
        guard force || compactor.policy.needsCompaction(before),
              let plan = compactor.plan(for: state.context) else { return }
        trace.record(.compactionStarted, metrics: [.contextTokens: before, .forced: force ? 1 : 0])
        let replacement: [AgentMessage]?
        do {
            let history = try await summarize(compactor.historySummaryRequest(for: plan), state: &state, events: events, trace: trace)
            let prefix = try await summarize(compactor.turnPrefixSummaryRequest(for: plan), state: &state, events: events, trace: trace)
            if history != .unusable, prefix != .unusable {
                replacement = compactor.applying(plan, historySummary: history.text, turnPrefixSummary: prefix.text)
            } else {
                replacement = force ? compactor.omitting(plan) : nil
            }
        } catch {
            trace.record(.compactionFailed)
            try Task.checkCancellation()
            guard isContextOverflow(error) else { throw error }
            replacement = compactor.omitting(plan)
        }
        guard let compacted = replacement, compacted != state.context else {
            trace.record(.compactionSkipped)
            return
        }
        let estimatedAfter = compactor.estimateTokens(systemPrompt: settings.systemPrompt, messages: compacted, tools: settings.tools)
        guard estimatedAfter < before else {
            trace.record(.compactionSkipped, metrics: [.contextTokens: before, .afterTokens: estimatedAfter])
            return
        }
        state.context = compacted
        state.usageAnchor = nil
        let after = contextTokens(settings, state: state)
        trace.record(.compactionFinished, metrics: [.contextTokens: before, .afterTokens: after])
        events.yield(.contextCompacted(beforeTokens: before, afterTokens: after))
    }

    private enum SummaryResult: Equatable {
        case skipped, unusable, text(String)

        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    private func summarize(_ request: AgentTurnRequest?, state: inout RunState,
                           events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                           trace: AgentTraceEmitter) async throws -> SummaryResult {
        guard let request else { return .skipped }
        trace.record(.summaryStarted, metrics: [.maxOutputTokens: request.maxOutputTokens,
                                               .omittedCharacters: request.contextOmittedCharacters])
        let response: AgentTurnResponse
        do { response = try await model.streamTurn(request) { _ in } }
        catch { trace.record(.summaryFailed); throw error }
        try Task.checkCancellation()
        record(response.usage, state: &state, events: events)
        trace.record(.summaryFinished)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return response.stopReason == .maxTokens || text.isEmpty ? .unusable : .text(text)
    }

    private func execute(_ calls: [NormalizedToolCall], tools: [AgentTool], state: inout RunState,
                         events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                         trace: AgentTraceEmitter) async throws -> AgentRunStopReason? {
        var stop: AgentRunStopReason?
        for normalized in calls {
            try Task.checkCancellation()
            let call = normalized.call
            state.requestedCalls += 1
            trace.record(.toolRequested, metrics: [.callOrdinal: state.requestedCalls, .toolCalls: state.toolCalls])
            if costLimitReached(state) { stop = .costLimit }
            else if state.toolCalls >= limits.maxToolCalls { stop = .toolCallLimit }
            events.yield(.toolStarted(callID: call.id, name: call.name, arguments: call.arguments))
            let output: AgentToolOutput
            let isError: Bool
            if let stop {
                recordLimit(stop, state: &state, trace: trace)
                trace.record(.toolSkipped, metrics: [.callOrdinal: state.requestedCalls], reason: stop)
                output = AgentToolOutput(content: "Tool not executed: \(stop.rawValue) reached.",
                                         summary: "Tool not executed: \(stop.rawValue) reached.")
                isError = true
            } else {
                state.toolCalls += 1
                (output, isError) = try await executeOne(normalized, tools: tools)
            }
            let result = AgentMessage.toolResult(callID: call.id, toolName: call.name,
                                                 content: output.content, isError: isError)
            state.history.append(result)
            state.context.append(result)
            var metrics = output.metrics
            metrics[.callOrdinal] = state.requestedCalls
            metrics[.isError] = isError ? 1 : 0
            trace.record(.toolFinished, metrics: metrics)
            events.yield(.toolFinished(callID: call.id, name: call.name, summary: output.summary, isError: isError))
        }
        return stop
    }

    private func executeOne(_ normalized: NormalizedToolCall, tools: [AgentTool]) async throws -> (AgentToolOutput, Bool) {
        let call = normalized.call
        do {
            guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
                return toolError("Unknown tool: \(call.name).")
            }
            guard normalized.hasValidArguments else {
                return toolError("Invalid JSON arguments for \(call.name): \(call.rawArguments)")
            }
            if tool.requiresConfirmation {
                let approved = await confirm(call)
                try Task.checkCancellation()
                if !approved { return toolError("Confirmation declined for \(call.name).") }
            }
            let output = try await tool.execute(call.arguments)
            try Task.checkCancellation()
            return (output, output.isError)
        } catch {
            try Task.checkCancellation()
            return toolError("Tool \(call.name) failed: \(error.localizedDescription)")
        }
    }

    private func toolError(_ text: String) -> (AgentToolOutput, Bool) {
        (AgentToolOutput(content: text, summary: text), true)
    }
}

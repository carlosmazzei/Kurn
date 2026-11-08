import Foundation

/// Sequential provider-neutral agent loop. Tool failures are conversation data.
public struct NativeHarness: Sendable {
    private let model: any AgentModel
    private let limits: AgentLimits
    private let costEstimator: (@Sendable (AgentUsage) -> Double)?
    private let compactor: AgentContextCompactor
    private let confirm: @Sendable (AgentToolCall) async -> Bool
    private let isContextOverflow: @Sendable (Error) -> Bool

    /// Appended to the system prompt for the tool-less wrap-up turn after a turn or tool-call limit.
    public static let wrapUpInstruction = """
        The tool budget for this answer is exhausted. Do not call any tools. Answer now using only the \
        information already gathered above, and say briefly which parts could not be checked.
        """

    /// - Parameter isContextOverflow: recognizes a provider rejecting a request as too long; the
    ///   harness then compacts against the real limit and retries that turn once.
    public init(model: any AgentModel, limits: AgentLimits = AgentLimits(),
                costEstimator: (@Sendable (AgentUsage) -> Double)? = nil,
                contextPolicy: AgentContextPolicy = AgentContextPolicy(inputTokenBudget: 23_000),
                tokenEstimator: @escaping @Sendable (String) -> Int = { ($0.count + 3) / 4 },
                isContextOverflow: @escaping @Sendable (Error) -> Bool = { _ in false },
                confirm: @escaping @Sendable (AgentToolCall) async -> Bool = { _ in false }) {
        self.model = model
        self.limits = limits
        self.costEstimator = costEstimator
        self.compactor = AgentContextCompactor(policy: contextPolicy, tokenEstimator: tokenEstimator)
        self.isContextOverflow = isContextOverflow
        self.confirm = confirm
    }

    public func run(systemPrompt: String, history: [AgentMessage], prompt: String,
                    tools: [AgentTool], maxOutputTokens: Int) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await drive(systemPrompt: systemPrompt, history: history, prompt: prompt,
                                    tools: tools, maxOutputTokens: maxOutputTokens, events: continuation)
                    continuation.finish()
                } catch {
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
        var turns = 0
        var finalText = ""
        var calibration = AgentContextCalibration()
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
                       maxOutputTokens: Int, events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        let messages = history + [.user(prompt)]
        var state = RunState(history: messages, context: messages)
        let specs = tools.map(\.spec)
        var reason = AgentRunStopReason.turnLimit
        events.yield(.runStarted)
        let settings = TurnSettings(systemPrompt: systemPrompt, tools: specs, maxOutputTokens: maxOutputTokens)
        for _ in 0..<limits.maxTurns {
            try Task.checkCancellation()
            if costLimitReached(state) { reason = .costLimit; break }
            guard let response = try await modelTurn(settings, state: &state, events: events) else {
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
            let stop = try await execute(calls, tools: tools, state: &state, events: events)
            if let stop { reason = stop; break }
        }
        try Task.checkCancellation()
        if limits.wrapUpOnLimit, reason == .turnLimit || reason == .toolCallLimit,
           case .toolResult? = state.context.last, !costLimitReached(state),
           try await wrapUp(settings, state: &state, events: events) == .maxTokens {
            reason = .outputLimit
        }
        try Task.checkCancellation()
        events.yield(.runFinished(AgentRunOutcome(messages: state.history, finalText: state.finalText,
                                                 stopReason: reason, totalUsage: state.usage)))
    }

    /// One text-only answer from what the run already gathered, instead of ending on tool results.
    /// Tools stay declared (some vendors reject tool history without them) but tool choice is "none";
    /// calls a vendor returns anyway are dropped. A reply without text is left as no answer, so the
    /// limit stays visible with an empty answer. Returns the wrap-up turn's stop reason.
    private func wrapUp(_ settings: TurnSettings, state: inout RunState,
                        events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws -> AgentModelStopReason? {
        let wrapUp = TurnSettings(systemPrompt: settings.systemPrompt + "\n\n" + Self.wrapUpInstruction,
                                  tools: settings.tools, maxOutputTokens: settings.maxOutputTokens, allowsToolCalls: false)
        guard let response = try await modelTurn(wrapUp, state: &state, events: events) else { return nil }
        try Task.checkCancellation()
        state.finalText = response.text
        if !response.text.isEmpty {
            let assistant = AgentMessage.assistant(text: response.text, toolCalls: [])
            state.history.append(assistant)
            state.context.append(assistant)
        }
        return response.stopReason
    }

    /// Compacts against the calibrated context size, streams one turn and calibrates from its usage.
    /// A context-overflow rejection compacts against the provider's real limit and retries once,
    /// provided nothing was streamed yet and compaction actually shrank the context. Returns nil when
    /// a compaction summary exhausted the cost limit before the turn could be sent.
    private func modelTurn(_ settings: TurnSettings, state: inout RunState,
                           events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws -> AgentTurnResponse? {
        events.yield(.turnStarted(index: state.turns))
        state.turns += 1
        var estimate = try await compact(settings, state: &state, events: events)
        var retried = false
        while true {
            if costLimitReached(state) { return nil }
            let streamed = StreamFlag()
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
                record(response.usage, state: &state, events: events)
                if let input = response.usage?.inputTokens {
                    state.calibration.record(estimated: estimate, reported: input)
                }
                return response
            } catch {
                try Task.checkCancellation()
                guard !retried, !streamed.value, isContextOverflow(error) else { throw error }
                retried = true
                state.calibration.recordOverflow(estimated: estimate, budget: compactor.policy.inputTokenBudget)
                let previous = state.context
                estimate = try await compact(settings, state: &state, events: events, force: true)
                guard state.context != previous else { throw error }
            }
        }
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

    /// Returns the raw estimate of the request about to be sent, for calibration against usage.
    /// `force` (after a provider rejected the request as too long) skips the threshold checks: old
    /// results are always elided, and the older prefix is summarized when elision changed nothing,
    /// since the provider's limit may sit far below the configured budget.
    private func compact(_ settings: TurnSettings, state: inout RunState,
                         events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                         force: Bool = false) async throws -> Int {
        func measure() -> Int {
            compactor.estimateTokens(systemPrompt: settings.systemPrompt, messages: state.context, tools: settings.tools)
        }
        let rawBefore = measure()
        let before = state.calibration.tokens(rawBefore)
        guard force || compactor.policy.needsCompaction(before) else { return rawBefore }
        let unelided = state.context
        state.context = compactor.elidingOldResults(in: state.context)
        let summarize = force ? state.context == unelided
            : compactor.policy.needsCompaction(state.calibration.tokens(measure()))
        if summarize,
           let request = compactor.summaryRequest(for: state.context, maxOutputTokens: settings.maxOutputTokens) {
            do {
                let summary = try await model.streamTurn(request) { _ in }
                try Task.checkCancellation()
                record(summary.usage, state: &state, events: events)
                if summary.stopReason != .maxTokens {
                    state.context = compactor.replacingOlderPrefix(in: state.context, summary: summary.text)
                }
            } catch {
                // The older prefix alone is too long for the provider to summarize: drop it rather
                // than abandon recovery; recent messages and the outcome's full history are kept.
                try Task.checkCancellation()
                guard isContextOverflow(error) else { throw error }
                state.context = compactor.omittingOlderPrefix(in: state.context)
            }
        }
        let rawAfter = measure()
        let after = state.calibration.tokens(rawAfter)
        if after != before { events.yield(.contextCompacted(beforeTokens: before, afterTokens: after)) }
        return rawAfter
    }

    private func execute(_ calls: [NormalizedToolCall], tools: [AgentTool], state: inout RunState,
                         events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws -> AgentRunStopReason? {
        var stop: AgentRunStopReason?
        for normalized in calls {
            try Task.checkCancellation()
            let call = normalized.call
            if costLimitReached(state) { stop = .costLimit }
            else if state.toolCalls >= limits.maxToolCalls { stop = .toolCallLimit }
            events.yield(.toolStarted(callID: call.id, name: call.name, arguments: call.arguments))
            let output: AgentToolOutput
            let isError: Bool
            if let stop {
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

import Foundation

/// Sequential provider-neutral agent loop. Tool failures are conversation data.
public struct NativeHarness: Sendable {
    private let model: any AgentModel
    private let limits: AgentLimits
    private let costEstimator: (@Sendable (AgentUsage) -> Double)?
    private let compactor: AgentContextCompactor
    private let confirm: @Sendable (AgentToolCall) async -> Bool

    public init(model: any AgentModel, limits: AgentLimits = AgentLimits(),
                costEstimator: (@Sendable (AgentUsage) -> Double)? = nil,
                contextPolicy: AgentContextPolicy = AgentContextPolicy(budget: .conservative),
                confirm: @escaping @Sendable (AgentToolCall) async -> Bool = { _ in false }) {
        self.model = model
        self.limits = limits
        self.costEstimator = costEstimator
        self.compactor = AgentContextCompactor(policy: contextPolicy)
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
        var finalText = ""
    }

    private func drive(systemPrompt: String, history: [AgentMessage], prompt: String, tools: [AgentTool],
                       maxOutputTokens: Int, events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        let messages = history + [.user(prompt)]
        var state = RunState(history: messages, context: messages)
        let specs = tools.map(\.spec)
        var reason = AgentRunStopReason.turnLimit
        events.yield(.runStarted)
        for turn in 0..<limits.maxTurns {
            try Task.checkCancellation()
            if costLimitReached(state) { reason = .costLimit; break }
            events.yield(.turnStarted(index: turn))
            try await compact(systemPrompt: systemPrompt, tools: specs, maxOutputTokens: maxOutputTokens,
                              state: &state, events: events)
            if costLimitReached(state) { reason = .costLimit; break }
            let response = try await model.streamTurn(
                AgentTurnRequest(systemPrompt: systemPrompt, messages: state.context,
                                 tools: specs, maxOutputTokens: maxOutputTokens)
            ) { event in
                if case .textDelta(let text) = event { events.yield(.textDelta(text)) }
            }
            try Task.checkCancellation()
            record(response.usage, state: &state, events: events)
            state.finalText = response.text
            let assistant = AgentMessage.assistant(text: response.text,
                                                   toolCalls: response.stopReason == .maxTokens ? [] : response.toolCalls)
            state.history.append(assistant)
            state.context.append(assistant)
            if response.stopReason == .maxTokens {
                reason = .outputLimit
                break
            }
            if response.toolCalls.isEmpty {
                reason = costLimitReached(state) ? .costLimit : .completed
                break
            }
            let stop = try await execute(response.toolCalls, tools: tools, state: &state, events: events)
            if let stop { reason = stop; break }
        }
        try Task.checkCancellation()
        events.yield(.runFinished(AgentRunOutcome(messages: state.history, finalText: state.finalText,
                                                 stopReason: reason, totalUsage: state.usage)))
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

    private func compact(systemPrompt: String, tools: [AgentToolSpec], maxOutputTokens: Int,
                         state: inout RunState,
                         events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        let before = compactor.estimateTokens(systemPrompt: systemPrompt, messages: state.context, tools: tools)
        guard compactor.policy.needsCompaction(before) else { return }
        state.context = compactor.elidingOldResults(in: state.context)
        let elided = compactor.estimateTokens(systemPrompt: systemPrompt, messages: state.context, tools: tools)
        if compactor.policy.needsCompaction(elided),
           let request = compactor.summaryRequest(for: state.context, maxOutputTokens: maxOutputTokens) {
            let summary = try await model.streamTurn(request) { _ in }
            try Task.checkCancellation()
            record(summary.usage, state: &state, events: events)
            if summary.stopReason != .maxTokens {
                state.context = compactor.replacingOlderPrefix(in: state.context, summary: summary.text)
            }
        }
        let after = compactor.estimateTokens(systemPrompt: systemPrompt, messages: state.context, tools: tools)
        if after != before { events.yield(.contextCompacted(beforeTokens: before, afterTokens: after)) }
    }

    private func execute(_ calls: [AgentToolCall], tools: [AgentTool], state: inout RunState,
                         events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws -> AgentRunStopReason? {
        var stop: AgentRunStopReason?
        for originalCall in calls {
            try Task.checkCancellation()
            let arguments = try? JSONValue.parse(originalCall.rawArguments)
            var call = originalCall
            call.arguments = arguments ?? .null
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
                (output, isError) = try await executeOne(call, arguments: arguments, tools: tools)
            }
            let result = AgentMessage.toolResult(callID: call.id, toolName: call.name,
                                                 content: output.content, isError: isError)
            state.history.append(result)
            state.context.append(result)
            events.yield(.toolFinished(callID: call.id, name: call.name, summary: output.summary, isError: isError))
        }
        return stop
    }

    private func executeOne(_ call: AgentToolCall, arguments: JSONValue?,
                            tools: [AgentTool]) async throws -> (AgentToolOutput, Bool) {
        do {
            guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
                return toolError("Unknown tool: \(call.name).")
            }
            guard let arguments else {
                return toolError("Invalid JSON arguments for \(call.name): \(call.rawArguments)")
            }
            if tool.requiresConfirmation {
                let approved = await confirm(call)
                try Task.checkCancellation()
                if !approved { return toolError("Confirmation declined for \(call.name).") }
            }
            let output = try await tool.execute(arguments)
            try Task.checkCancellation()
            return (output, false)
        } catch {
            try Task.checkCancellation()
            return toolError("Tool \(call.name) failed: \(error.localizedDescription)")
        }
    }

    private func toolError(_ text: String) -> (AgentToolOutput, Bool) {
        (AgentToolOutput(content: text, summary: text), true)
    }
}

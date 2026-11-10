import Foundation

extension NativeHarness {
    private struct Work: Sendable {
        let normalized: NormalizedToolCall
        let invocation: AgentToolInvocation
        let ordinal: Int
        let blocked: AgentRunStopReason?
    }

    func execute(_ calls: [NormalizedToolCall], requestID: String?, tools: [AgentTool], state: inout AgentRunState,
                 events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter) async throws -> AgentRunStopReason? {
        guard let requestID else { throw AgentWireError.invalidResponse }
        let registry = try AgentToolRegistry(tools)
        let pipeline = AgentToolPipeline(registry: registry, policy: toolPolicy, confirm: confirm, events: events, trace: trace)
        let parallel = calls.allSatisfy { registry.tool(named: $0.call.name)?.scheduling == .parallelRead }
        if !parallel {
            var stop: AgentRunStopReason?
            for call in calls {
                try Task.checkCancellation()
                let work = try prepare(call, requestID: requestID, stop: &stop, state: &state, events: events, trace: trace)
                let result = try await perform(work, pipeline: pipeline)
                try append(result, work: work, state: &state, events: events, trace: trace)
            }
            return stop
        }
        var stop: AgentRunStopReason?
        var offset = 0
        while offset < calls.count {
            try Task.checkCancellation()
            // Settle the currently authorized capacity before considering an extension. Preparing
            // the entire batch upfront would deny progress earned by its own completed reads.
            let capacity = stop == nil ? max(1, state.allowedToolCalls - state.toolCalls) : calls.count
            let count = min(capacity, calls.count - offset)
            let work = try calls[offset..<(offset + count)].map {
                try prepare($0, requestID: requestID, stop: &stop, state: &state, events: events, trace: trace)
            }
            let results = await performParallel(work, pipeline: pipeline)
            var failure: Error?
            for (index, result) in results {
                switch result {
                case .success(let result): try append(result, work: work[index], state: &state, events: events, trace: trace)
                case .failure(let error): failure = failure ?? error
                }
            }
            if let failure { throw failure }
            offset += count
        }
        return stop
    }

    private func performParallel(_ work: [Work], pipeline: AgentToolPipeline) async -> [(Int, Result<AgentToolExecution, Error>)] {
        let workers = min(maxParallelReads, work.count)
        return await withTaskGroup(of: [(Int, Result<AgentToolExecution, Error>)].self) { group in
            for worker in 0..<workers {
                group.addTask {
                    var results: [(Int, Result<AgentToolExecution, Error>)] = []
                    for index in stride(from: worker, to: work.count, by: workers) {
                        do { results.append((index, .success(try await perform(work[index], pipeline: pipeline)))) }
                        catch { results.append((index, .failure(error))) }
                    }
                    return results
                }
            }
            var results: [(Int, Result<AgentToolExecution, Error>)] = []
            for await completed in group { results += completed }
            return results.sorted { $0.0 < $1.0 }
        }
    }

    private func prepare(_ normalized: NormalizedToolCall, requestID: String, stop: inout AgentRunStopReason?, state: inout AgentRunState,
                         events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter) throws -> Work {
        let call = normalized.call
        let invocation = try AgentMessageFactory.invocation(call, requestID: requestID)
        trace.register(invocation)
        state.requestedCalls += 1
        trace.record(.toolRequested, metrics: [.callOrdinal: state.requestedCalls, .toolCalls: state.toolCalls], invocation: invocation)
        if stop == nil {
            if costLimitReached(state) { stop = .costLimit }
            else if state.toolCalls >= state.allowedToolCalls,
                    !state.extendBudget(.toolCallLimit, limits: limits, trace: trace) { stop = .toolCallLimit }
        }
        if let stop {
            recordLimit(stop, state: &state, trace: trace)
            trace.record(.toolSkipped, metrics: [.callOrdinal: state.requestedCalls], reason: stop, invocation: invocation)
        } else { state.toolCalls += 1 }
        events.yield(.toolStarted(callID: call.id, name: call.name, arguments: call.arguments))
        return Work(normalized: normalized, invocation: invocation, ordinal: state.requestedCalls, blocked: stop)
    }

    private func perform(_ work: Work, pipeline: AgentToolPipeline) async throws -> AgentToolExecution {
        if let stop = work.blocked {
            let result = AgentToolExecution.failure("Tool not executed: \(stop.rawValue) reached.", AgentToolBlockReason(rawValue: stop.rawValue))
            pipeline.trace.record(.toolFinished, metrics: [.isError: 1], invocation: work.invocation)
            pipeline.events.yield(.toolFinished(callID: work.normalized.call.id, name: work.normalized.call.name,
                summary: result.output.summary, isError: true))
            return result
        }
        return try await pipeline.execute(work.normalized, invocation: work.invocation)
    }

    private func append(_ execution: AgentToolExecution, work: Work, state: inout AgentRunState,
                        events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter) throws {
        let output = execution.output
        if limits.continuation != nil, work.blocked == nil { state.recordProgress(call: work.normalized.call, output: output, isError: execution.isError) }
        let result = try AgentMessageFactory.result(work.invocation, output: output, isError: execution.isError, syntheticReason: execution.reason)
        events.yield(.messageAppended(result))
        state.history.append(result); state.context.append(result)
        var metrics = output.metrics; metrics[.callOrdinal] = work.ordinal
        if (metrics[.omittedScalars] ?? 0) > 0 || (metrics[.omittedItems] ?? 0) > 0 {
            trace.record(.payloadClipped, metrics: metrics, invocation: work.invocation)
        }
        if (metrics[.deferredScalars] ?? 0) > 0 || (metrics[.deferredItems] ?? 0) > 0 {
            trace.record(.payloadPaged, metrics: metrics, invocation: work.invocation)
        }
    }
}

import Foundation

extension NativeHarness {
    /// Compacts when the context outgrows the window, streams one turn and anchors the context size
    /// to the usage it reports. A context-overflow rejection compacts and retries once, provided
    /// nothing was streamed yet and compaction actually shrank the context. Returns nil when a
    /// compaction summary exhausted the cost limit before the turn could be sent.
    func modelTurn(_ settings: inout TurnSettings, state: inout AgentRunState,
                           events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                           trace: AgentTraceEmitter) async throws -> AgentTurnResponse? {
        events.yield(.turnStarted(index: state.turns))
        state.turns += 1
        var retried = false
        // Session-owned retries (NH07): attempts of this turn's request and the time waited.
        var attempts = 1
        var waited = 0.0
        while true {
            state.responseAlreadyAudited = false
            if costLimitReached(state) { return nil }
            try await compact(settings, state: &state, events: events, trace: trace)
            if costLimitReached(state) { return nil }
            settings.outputBudget.fit(inputTokens: contextTokens(settings, state: state))
            let requestIdentity = AgentRequestIdentity(purpose: settings.allowsToolCalls ? .response : .wrapUp)
            trace.beginRequest(requestIdentity)
            defer { trace.endRequest(requestIdentity) }
            let stream = AgentTurnStream(events: events, trace: trace, request: requestIdentity, descriptor: model.descriptor)
            let started = ContinuousClock.now
            var requestMetrics = settings.outputBudget.diagnosticMetrics
            requestMetrics.merge([.turnIndex: state.turns - 1, .messageCount: state.context.count,
                                  .toolCount: settings.tools.count]) { _, current in current }
            trace.record(.requestStarted, metrics: requestMetrics)
            let response: AgentTurnResponse
            do {
                let raw = try await model.streamTurn(
                    AgentTurnRequest(systemPrompt: settings.systemPrompt, messages: state.context,
                                     tools: settings.tools, maxOutputTokens: settings.maxOutputTokens,
                                     allowsToolCalls: settings.allowsToolCalls).identified(requestIdentity)
                ) { stream.consume($0) }
                response = try stream.complete(raw)
                try Task.checkCancellation()
            } catch let caught {
                // A host's `Retry-After` hint only shapes the wait; everything else sees the failure.
                let error = AgentRetryAfter.unwrapped(caught)
                stream.fail(error)
                try await recordFailure(stream, state: &state, events: events, trace: trace)
                trace.record(.requestFailed, metrics: [.durationMs: Self.milliseconds(since: started), .protocolFailure: stream.failureCode])
                trace.endRequest(requestIdentity)
                try Task.checkCancellation()
                // A transient failure before any visible text is sent again as a new request, after a
                // cancellable wait; a cancel during it starts no new attempt.
                if !stream.hasVisibleText,
                   let delay = retryPolicy.delay(after: caught, failedAttempts: attempts, waited: waited) {
                    trace.record(.requestRetryScheduled, metrics: [.requestAttempt: attempts,
                                                                   .retryDelayMs: Int((delay * 1_000).rounded())])
                    try await retryPolicy.sleep(delay)
                    try Task.checkCancellation()
                    attempts += 1
                    waited += delay
                    continue
                }
                guard !retried, !stream.hasVisibleText, isContextOverflow(error) else { throw error }
                retried = true
                switch try await compact(settings, state: &state, events: events, trace: trace, force: true) {
                case .reduced: continue
                // No usable summary: the run fails explicitly rather than continuing on a note.
                case .failed: throw AgentContextReductionError()
                case .unchanged: throw error
                }
            }
            var metrics = response.diagnosticMetrics
            metrics[.durationMs] = Self.milliseconds(since: started)
            metrics[.maxOutputTokens] = settings.maxOutputTokens
            metrics[.turnIndex] = state.turns - 1
            metrics[.streamedText] = stream.hasVisibleText ? 1 : 0
            trace.record(.requestFinished, metrics: metrics, reason: response.stopReason == .maxTokens ? .outputLimit : nil)
            trace.endRequest(requestIdentity)
            try await record(response.usage, request: requestIdentity, state: &state, events: events)
            if response.stopReason == .maxTokens,
               try await recoverOutput(response, streamed: stream.hasVisibleText, settings: &settings,
                                       state: &state, events: events, trace: trace) { continue }
            if let usage = response.usage, usage.inputTokens > 0 {
                // The caller appends this reply, so the anchor covers one more message.
                state.usageAnchor = (usage.inputTokens + usage.outputTokens, state.context.count + 1)
            }
            return response
        }
    }

    private func recoverOutput(_ response: AgentTurnResponse, streamed: Bool, settings: inout TurnSettings,
                               state: inout AgentRunState, events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                               trace: AgentTraceEmitter) async throws -> Bool {
        let costReached = costLimitReached(state)
        var facts = settings.outputBudget.recoveryMetrics(response, streamed: streamed, state: state, costReached: costReached)
        guard settings.outputBudget.canRecover(response, streamed: streamed, state: state, costReached: costReached) else {
            trace.record(.outputRetryDenied, metrics: facts, reason: .outputLimit)
            return false
        }
        settings.outputBudget.didRecover()
        facts[.outputRetries] = settings.outputBudget.retries
        trace.record(.outputRetryStarted, metrics: facts, reason: .outputLimit)
        let interrupted = try response.auditMessage()
        try await publish(interrupted, events: events)
        state.history.append(interrupted)
        try await AgentResponseAudit.appendBlocked(response, state: &state, events: events, trace: trace, toContext: false, commit: messageCommit)
        state.responseAlreadyAudited = true
        if let usage = response.usage, usage.inputTokens > 0 {
            // Preserve reported input size without counting the discarded response or its calls.
            state.usageAnchor = (usage.inputTokens, state.context.count)
        }
        guard try await compact(settings, state: &state, events: events, trace: trace, force: true) == .reduced else {
            trace.record(.outputRetryDenied, metrics: facts, reason: .outputLimit)
            return false
        }
        events.yield(.turnStarted(index: state.turns))
        state.turns += 1
        return true
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let parts = start.duration(to: .now).components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    func recordLimit(_ reason: AgentRunStopReason, state: inout AgentRunState, trace: AgentTraceEmitter) {
        guard state.firstLimit == nil else { return }
        state.firstLimit = reason
        trace.record(.limitReached, metrics: [.toolCalls: state.toolCalls, .maxToolCalls: state.allowedToolCalls,
                                             .turnIndex: state.turns, .maxTurns: state.allowedTurns], reason: reason)
    }

    /// A cost ceiling is checked only against a known cost (NH07). Without a price source, or
    /// once a usage could not be priced, the ceiling cannot be verified, so it counts as reached:
    /// an unchecked ceiling must never let a run keep spending.
    func costLimitReached(_ state: AgentRunState) -> Bool {
        guard let ceiling = limits.maxCostUSD else { return false }
        guard costEstimator != nil, state.costKnown else { return true }
        return state.cost >= ceiling
    }

    private func record(_ usage: AgentUsage?, request: AgentRequestIdentity, state: inout AgentRunState,
                        events: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        guard let usage else { return }
        try await usageCommit(usage, request)
        state.usage = state.usage.adding(usage)
        if let price = costEstimator?(usage) { state.cost += max(0, price) } else { state.costKnown = false }
        events.yield(.usage(usage))
    }

    /// The context size of the next request: the provider-reported size of the latest turn plus
    /// estimates of the messages appended since, or a full estimate before any usage is known.
    private func contextTokens(_ settings: TurnSettings, state: AgentRunState) -> Int {
        if let anchor = state.usageAnchor, anchor.contextCount <= state.context.count {
            return anchor.tokens + compactor.estimateTokens(of: state.context[anchor.contextCount...])
        }
        return compactor.estimateTokens(systemPrompt: settings.systemPrompt, messages: state.context,
                                        tools: settings.tools)
    }

    enum CompactionResult: Equatable {
        /// The context was replaced by a summary and the kept messages, and is smaller.
        case reduced
        /// Nothing needed or could be compacted, or the result would not be smaller.
        case unchanged
        /// A summary was needed but none was usable: unusable, cut off, or too long to request.
        case failed
    }

    /// Compacts once the context exceeds the window minus the reserve, or unconditionally (`force`)
    /// after a provider rejected the request as too long. Older messages are replaced by a summary
    /// and the newest `keepRecentTokens` are kept. A summary that is cut off, unusable, or whose own
    /// request is too long leaves the context unchanged and reports `.failed`: nothing stands in
    /// for a summary (NH06), so the caller decides whether that ends the run.
    @discardableResult
    func compact(_ settings: TurnSettings, state: inout AgentRunState,
                 events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter,
                 force: Bool = false) async throws -> CompactionResult {
        let before = contextTokens(settings, state: state)
        let threshold = compactor.policy.compactionThreshold
        trace.record(.contextCheck, metrics: [.contextTokens: before, .thresholdTokens: threshold,
                                             .retainedTokens: compactor.policy.effectiveKeepRecentTokens, .forced: force ? 1 : 0])
        guard force || before > threshold,
              let plan = compactor.plan(for: state.context) else { return .unchanged }
        trace.record(.compactionStarted, metrics: [.contextTokens: before, .forced: force ? 1 : 0])
        let compacted: [AgentMessage]
        do {
            let history = try await summarize(compactor.historySummaryRequest(for: plan), state: &state, events: events, trace: trace)
            let prefix = try await summarize(compactor.turnPrefixSummaryRequest(for: plan), state: &state, events: events, trace: trace)
            guard history != .unusable, prefix != .unusable else {
                trace.record(.compactionFailed)
                return .failed
            }
            compacted = compactor.applying(plan, historySummary: history.text, turnPrefixSummary: prefix.text)
        } catch {
            trace.record(.compactionFailed)
            try Task.checkCancellation()
            guard isContextOverflow(error) else { throw error }
            return .failed
        }
        guard compacted != state.context else {
            trace.record(.compactionSkipped)
            return .unchanged
        }
        let estimatedAfter = compactor.estimateTokens(systemPrompt: settings.systemPrompt, messages: compacted, tools: settings.tools)
        guard estimatedAfter < before else {
            trace.record(.compactionSkipped, metrics: [.contextTokens: before, .afterTokens: estimatedAfter])
            return .unchanged
        }
        // The summary is a checkpoint, saved before any request uses it.
        if let checkpoint = AgentCompactionCheckpoint(compacted: compacted, tokensBefore: before,
                                                                  tokensAfter: estimatedAfter, splitTurn: plan.isSplitTurn) {
            try await compactionCommit(checkpoint)
        }
        state.context = compacted
        state.usageAnchor = nil
        let after = contextTokens(settings, state: state)
        trace.record(.compactionFinished, metrics: [.contextTokens: before, .afterTokens: after])
        events.yield(.contextCompacted(beforeTokens: before, afterTokens: after))
        return .reduced
    }

    private enum SummaryResult: Equatable {
        case skipped, unusable, text(String)

        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    private func summarize(_ request: AgentTurnRequest?, state: inout AgentRunState,
                           events: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                           trace: AgentTraceEmitter) async throws -> SummaryResult {
        guard let request else { return .skipped }
        var output = AgentOutputBudget(requested: nil, policy: compactor.policy)
        output.fit(inputTokens: compactor.estimateTokens(systemPrompt: request.systemPrompt, messages: request.messages, tools: request.tools))
        var metrics = output.diagnosticMetrics
        // This is a separate summary request, not the run's output-recovery counter.
        metrics.removeValue(forKey: .outputRetries)
        metrics.merge([.maxOutputTokens: request.maxOutputTokens, .omittedCharacters: request.contextOmittedCharacters,
                       .serializedToolOmittedCharacters: request.serializedToolOmittedCharacters,
                       .fittedHistoryOmittedCharacters: request.fittedHistoryOmittedCharacters]) { _, current in current }
        let response: AgentTurnResponse
        let requestIdentity = AgentRequestIdentity(purpose: .summary)
        trace.beginRequest(requestIdentity)
        defer { trace.endRequest(requestIdentity) }
        trace.record(.summaryStarted, metrics: metrics)
        let stream = AgentTurnStream(events: events, trace: trace, request: requestIdentity, descriptor: model.descriptor, forwardsText: false)
        do {
            let raw = try await model.streamTurn(request.identified(requestIdentity)) { stream.consume($0) }
            response = try stream.complete(raw)
        } catch let caught {
            let error = AgentRetryAfter.unwrapped(caught)
            stream.fail(error)
            // Summary failures are protocol/audit data, never usable compaction checkpoints.
            try await recordFailure(stream, state: &state, events: events, trace: trace)
            trace.record(.summaryFailed, metrics: [.protocolFailure: stream.failureCode])
            throw error
        }
        try Task.checkCancellation()
        if response.stopReason == .error || response.stopReason == .aborted || response.stopReason == .deferred {
            let message = try response.auditMessage()
            try await publish(message, events: events)
            state.history.append(message)
            try await AgentResponseAudit.appendBlocked(response, state: &state, events: events, trace: trace, toContext: false, commit: messageCommit)
        }
        try await record(response.usage, request: requestIdentity, state: &state, events: events)
        trace.record(.summaryFinished, metrics: response.diagnosticMetrics,
                     reason: response.stopReason == .maxTokens ? .outputLimit : nil)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return response.stopReason != .endTurn || !response.toolCalls.isEmpty || text.isEmpty ? .unusable : .text(text)
    }

    private func recordFailure(_ stream: AgentTurnStream, state: inout AgentRunState,
                               events: AsyncThrowingStream<AgentEvent, Error>.Continuation, trace: AgentTraceEmitter) async throws {
        guard let message = stream.failureMessage else { return }
        let failure = AgentMessage.content(message)
        try await publish(failure, events: events)
        state.history.append(failure)
        let response = AgentTurnResponse(text: message.text, message: message, blocksToolExecution: true)
        try await AgentResponseAudit.appendBlocked(response, state: &state, events: events, trace: trace, toContext: false, commit: messageCommit)
    }

}

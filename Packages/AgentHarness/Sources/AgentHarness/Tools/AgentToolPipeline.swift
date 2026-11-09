import Foundation

struct AgentToolExecution: Sendable {
    let output: AgentToolOutput
    let reason: AgentToolBlockReason?
    var isError: Bool { output.isError || reason != nil }
    static func failure(_ text: String, _ reason: AgentToolBlockReason? = nil) -> Self {
        Self(output: AgentToolOutput(content: text, summary: text, isError: true), reason: reason)
    }
}

/// One checked invocation, with an explicit correlation and a terminal progress fence.
struct AgentToolPipeline: Sendable {
    let registry: AgentToolRegistry
    let policy: AgentToolPolicy
    let confirm: @Sendable (AgentToolCall) async -> Bool
    let events: AsyncThrowingStream<AgentEvent, Error>.Continuation
    let trace: AgentTraceEmitter

    func execute(_ normalized: NativeHarness.NormalizedToolCall, invocation: AgentToolInvocation) async throws -> AgentToolExecution {
        let call = normalized.call
        let context = AgentToolExecutionContext(sessionID: trace.sessionID, invocation: invocation) { progress in
            let phases: [AgentToolProgress.Phase] = [.validating, .authorizing, .executing, .committing, .committed, .recoveredCommit]
            var metrics: [AgentDiagnostic.Metric: Int] = [.toolPhase: phases.firstIndex(of: progress.phase) ?? 0]
            if let count = progress.completed { metrics[.completedItems] = count }
            trace.record(.toolProgress, metrics: metrics, invocation: invocation)
            events.yield(.toolProgress(invocation: invocation, progress: progress))
        }
        defer { context.finish() }
        do {
            try Task.checkCancellation()
            context.progress(AgentToolProgress(.validating))
            let result = try await checked(normalized, context: context)
            _ = try AgentMessageFactory.result(invocation, output: result.output, isError: result.isError, syntheticReason: result.reason)
            context.finish()
            trace.record(.toolFinished, metrics: result.output.metrics.merging([.isError: result.isError ? 1 : 0]) { _, new in new }, invocation: invocation)
            events.yield(.toolFinished(callID: call.id, name: call.name, summary: result.output.summary, isError: result.isError))
            return result
        } catch {
            context.finish()
            // Tool cancellation has a terminal event even when the UI consumer has already left.
            if error is CancellationError { trace.record(.toolAborted, invocation: invocation) }
            trace.record(.toolFinished, metrics: [.isError: 1, .protocolFailure: AgentStreamFailure.classify(error).diagnosticCode], invocation: invocation)
            events.yield(.toolFinished(callID: call.id, name: call.name, summary: "Tool interrupted", isError: true))
            throw error
        }
    }

    private func checked(_ normalized: NativeHarness.NormalizedToolCall, context: AgentToolExecutionContext) async throws -> AgentToolExecution {
        let call = normalized.call
        guard call.namespace == nil else { return .failure("Namespaced tool calls are unsupported.", .unsupportedNamespace) }
        guard let tool = registry.tool(named: call.name) else { return .failure("Unknown tool: \(call.name).", .unknownTool) }
        guard normalized.hasValidArguments else { return invalid(context.invocation, "Invalid JSON arguments for \(call.name).") }
        do { try registry.validate(call.arguments, for: call.name) }
        catch { return invalid(context.invocation, "Invalid arguments for \(call.name).") }
        do {
            context.progress(AgentToolProgress(.authorizing))
            let decision = try await policy(context.invocation, call.arguments)
            try Task.checkCancellation()
            guard case .allow(let arguments) = decision else {
                trace.record(.toolPolicyDenied, invocation: context.invocation)
                return .failure("Tool denied by policy.", .policyDenied)
            }
            do { try registry.validate(arguments, for: call.name) }
            catch { return invalid(context.invocation, "Invalid policy-transformed arguments for \(call.name).") }
            if tool.requiresConfirmation {
                let transformed = AgentToolCall(id: call.id, name: call.name, arguments: arguments,
                    rawArguments: try arguments.encodedString(), providerMetadata: call.providerMetadata,
                    namespace: call.namespace, invocationID: call.invocationID)
                let approved = await confirm(transformed)
                try Task.checkCancellation()
                if !approved { return .failure("Confirmation declined for \(call.name).", .confirmationDeclined) }
            }
            context.progress(AgentToolProgress(.executing))
            // A committed effect remains a success if cancellation arrives after its durable commit.
            // The owner checks cancellation before requesting another model turn.
            let output = try await tool.executeWithContext(arguments, context)
            return AgentToolExecution(output: output, reason: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return .failure("Tool \(call.name) failed.")
        }
    }

    private func invalid(_ invocation: AgentToolInvocation, _ message: String) -> AgentToolExecution {
        trace.record(.toolValidationFailed, invocation: invocation)
        return .failure(message, .invalidArguments)
    }
}

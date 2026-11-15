import Foundation
import Testing
@testable import AgentHarness

struct AgentContentRuntimeTests {
    @Test func authoritativeNativeFinalReplacesDraftAndDoesNotExecuteRemovedCalls() async throws {
        struct Model: AgentModel {
            let final: AgentContentMessage
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                onEvent(.textDelta("Wrong draft"))
                return AgentTurnResponse(text: "Ignored legacy projection", toolCalls: [agentCall("removed")], message: final)
            }
        }
        let final = try contentMessage([AgentContentBlock(id: "answer", content: .text("Correct final"))], usage: AgentUsage(inputTokens: 12, outputTokens: 3))
        let tool = AgentTool(spec: agentTool().spec) { _ in Issue.record("Removed calls must never execute"); return AgentToolOutput(content: "", summary: "") }
        let events = try await agentEvents(NativeHarness(model: Model(final: final)), tools: [tool])
        let outcome = try agentOutcome(events)
        #expect(outcome.finalText == "Correct final" && outcome.totalUsage == final.usage)
        guard case .content(let accepted) = outcome.messages.last else { Issue.record("Missing native final"); return }
        #expect(accepted.blocks == final.blocks && accepted.timestampMilliseconds == final.timestampMilliseconds)
        #expect(accepted.identity?.requestID != nil)
        #expect(!events.contains { if case .toolStarted = $0 { return true }; return false })
        #expect(events.contains(.modelContent(.messageFinished(accepted))))
    }

    @Test func nativeInvalidArgumentsProduceErrorDataAndContentFreeDiagnostics() async throws {
        let call = agentCall("call", raw: "{private-invalid")
        let valid = agentCall("valid", raw: #"{"ok":true}"#)
        let native = try contentMessage([AgentContentBlock(id: "call", content: .toolCall(call, complete: true)),
            AgentContentBlock(id: "valid", content: .toolCall(valid, complete: true))], stop: .toolUse)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", message: native), AgentTurnResponse(text: "Recovered")])
        let tool = AgentTool(spec: agentTool().spec, requiresConfirmation: true) { arguments in
            #expect(arguments == .object(["ok": .bool(true)]))
            return AgentToolOutput(content: "Valid result", summary: "Valid result")
        }
        let capture = DiagnosticCapture()
        let harness = NativeHarness(model: model, confirm: { approved in #expect(approved.id == "valid"); return true },
                                    diagnosticSink: { capture.record($0) })
        let outcome = try agentOutcome(await agentEvents(harness, tools: [tool]))
        #expect(outcome.finalText == "Recovered")
        guard case .content(let accepted) = outcome.messages[1] else { Issue.record("Missing native assistant"); return }
        #expect(accepted.toolCalls.map(\.rawArguments) == native.toolCalls.map(\.rawArguments))
        #expect(accepted.toolCalls.allSatisfy { $0.invocationID != nil })
        guard case .tool(let invalid) = outcome.messages[2], invalid.invocation.callID == "call", invalid.isError, invalid.syntheticReason == .invalidArguments else { Issue.record("Missing validation result"); return }
        #expect(outcome.messages[3].legacyProjection == .toolResult(callID: "valid", toolName: "lookup", content: "Valid result", isError: false))
        #expect(capture.events.contains { $0.kind == .requestFinished && $0.metrics[.invalidToolCalls] == 1 })
        #expect(!capture.events.map(\.logLine).joined().contains("private-invalid"))
    }

    @Test(arguments: [AgentModelStopReason.deferred, .error, .aborted, .other("safety")])
    func nonExecutableTerminalReasonsNeverRunTools(reason: AgentModelStopReason) async throws {
        let native = try contentMessage([AgentContentBlock(id: "call", content: .toolCall(agentCall(), complete: false))], stop: reason)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", message: native)])
        let tool = AgentTool(spec: agentTool().spec) { _ in Issue.record("Non-executable response ran a tool"); return AgentToolOutput(content: "", summary: "") }
        var observed: [AgentEvent] = []
        do {
            for try await event in NativeHarness(model: model).run(systemPrompt: "", history: [], prompt: "Question", tools: [tool]) { observed.append(event) }
            Issue.record("Expected unsupported/error/abort outcome")
        } catch {
            #expect(observed.contains { if case .toolFinished(_, _, _, true) = $0 { return true }; return false })
            #expect(!observed.contains { if case .toolStarted = $0 { return true }; return false })
            #expect(observed.filter { if case .modelContent(.messageFinished) = $0 { return true }; return false }.count == 1)
        }
    }

    @Test(arguments: [false, true]) func terminalCallbacksFenceLateContentAndFailedCallbacksFenceExecution(failed: Bool) async throws {
        struct Model: AgentModel {
            let final: AgentContentMessage
            let failed: Bool
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                onEvent(.content(failed ? .failed(.preparation) : .messageFinished(final)))
                onEvent(.textDelta("late private text"))
                onEvent(.content(.failed(.transport)))
                return AgentTurnResponse(text: "", message: final)
            }
        }
        let final = try contentMessage([AgentContentBlock(id: "answer", content: .text("Final"))])
        var observed: [AgentEvent] = []
        let capture = DiagnosticCapture()
        do {
            let harness = NativeHarness(model: Model(final: final, failed: failed), diagnosticSink: { capture.record($0) })
            for try await event in harness.run(systemPrompt: "", history: [], prompt: "Question", tools: []) { observed.append(event) }
            let outcome = try agentOutcome(observed)
            #expect(!failed && outcome.finalText == "Final")
        } catch { #expect(failed) }
        #expect(!observed.contains(.textDelta("late private text")))
        #expect(observed.filter { if case .modelContent(.messageFinished) = $0 { return true }; if case .modelContent(.failed) = $0 { return true }; return false }.count == 1)
        if failed { #expect(capture.events.contains { $0.kind == .requestFailed && $0.metrics[.protocolFailure] == 1 }) }
    }
    @Test func lengthBlocksEveryCallAndKeepsPairedSyntheticResults() async throws {
        let calls = [agentCall("complete"), agentCall("incomplete", raw: "{private")]
        let message = try contentMessage([
            AgentContentBlock(id: "one", content: .toolCall(calls[0], complete: true)),
            AgentContentBlock(id: "two", content: .toolCall(calls[1], complete: false))
        ], stop: .maxTokens, usage: AgentUsage(inputTokens: 10, outputTokens: 512))
        let tool = AgentTool(spec: agentTool().spec) { _ in Issue.record("Length-limited response executed"); return AgentToolOutput(content: "", summary: "") }
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", message: message)])
        let events = try await agentEvents(NativeHarness(model: model), tools: [tool])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .outputLimit && outcome.messages.count == 4)
        guard case .content(let accepted) = outcome.messages[1] else { Issue.record("Missing native assistant"); return }
        #expect(accepted.hasIncompleteCalls && accepted.stopReason == .maxTokens)
        #expect(accepted.toolCalls.map(\.rawArguments) == calls.map(\.rawArguments))
        let errors = outcome.messages.compactMap { if case .tool(let result) = $0, result.isError, result.syntheticReason == .outputLimit { return result.invocation.callID }; return nil }
        #expect(errors == calls.map(\.id))
        #expect(!events.contains { if case .toolStarted = $0 { return true }; return false })
        #expect(try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(outcome.messages)) == outcome.messages)
    }

    @Test func recoveryCompactionFailureStillRecordsEveryBlockedInvocation() async throws {
        let capture = DiagnosticCapture()
        let model = ResultScriptedAgentModel([
            .success(AgentTurnResponse(text: "", toolCalls: [agentCall("blocked", raw: "{private")],
                usage: AgentUsage(inputTokens: 50_000, outputTokens: 20), stopReason: .maxTokens)),
            .failure(ScriptedAgentModel.Failure.provider)
        ])
        let policy = AgentContextPolicy(contextWindow: 1_050_000, keepRecentTokens: 100, maxOutputTokens: 128_000)
        let harness = NativeHarness(model: model, contextPolicy: policy, diagnosticSink: { capture.record($0) })
        let history: [AgentMessage] = [.user(tokens(500)), .assistant(text: tokens(500), toolCalls: [])]
        var observed: [AgentEvent] = []
        do {
            for try await event in harness.run(systemPrompt: "", history: history, prompt: "Question", tools: [agentTool()]) { observed.append(event) }
            Issue.record("Expected summary failure")
        } catch {
            #expect(observed.contains { if case .toolFinished("blocked", _, _, true) = $0 { return true }; return false })
            #expect(!observed.contains { if case .toolStarted = $0 { return true }; return false })
            #expect(capture.events.filter { $0.kind == .toolSkipped }.count == 1)
            #expect(capture.events.contains { $0.kind == .summaryFailed })
            #expect(capture.events.last?.kind == .runFailed)
        }
    }

}

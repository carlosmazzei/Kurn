import Foundation
import Testing
@testable import AgentHarness

struct AgentNativeIdentityTests {
    @Test func repeatedProviderIDsGetDistinctLocalInvocationsAndCorrelatedResults() async throws {
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "First", toolCalls: [agentCall("reused")]),
            AgentTurnResponse(text: "Second", toolCalls: [agentCall("reused")]),
            AgentTurnResponse(text: "Done")
        ])
        let capture = DiagnosticCapture()
        let context = AgentRunContext()
        var events: [AgentEvent] = []
        let harness = NativeHarness(model: model, diagnosticSink: { capture.record($0) })
        for try await event in harness.run(systemPrompt: "", history: [], prompt: "Question", tools: [agentTool()], context: context) {
            events.append(event)
        }
        let outcome = try agentOutcome(events)
        let requests = await model.requests
        let registered = events.compactMap { if case .invocationRegistered(let value) = $0 { return value }; return nil }
        let results = outcome.messages.compactMap { if case .tool(let value) = $0 { return value }; return nil }
        #expect(registered.count == 2 && Set(registered.map(\.id)).count == 2)
        #expect(registered.map(\.callID) == ["reused", "reused"])
        #expect(registered.map(\.requestID) == requests.prefix(2).compactMap { $0.identity?.id })
        #expect(results.map(\.invocation) == registered)
        let content = outcome.messages.compactMap { if case .content(let value) = $0 { return value }; return nil }
        #expect(content.count == 4 && content.allSatisfy { $0.timestampMilliseconds != nil })
        #expect(Set(content.map(\.id) + results.map(\.id)).count == outcome.messages.count)
        #expect(events.compactMap { if case .messageAppended(let message) = $0 { return message }; return nil } == outcome.messages)
        for invocation in registered {
            let registerIndex = try #require(events.firstIndex(of: .invocationRegistered(invocation)))
            let startIndex = try #require(events[registerIndex...].firstIndex { if case .toolStarted = $0 { return true }; return false })
            #expect(registerIndex < startIndex)
            let facts = capture.events.filter { $0.correlation?.invocationID == invocation.id }
            #expect(facts.map(\.kind) == [.toolRequested, .toolProgress, .toolProgress, .toolProgress, .toolFinished])
            #expect(facts.allSatisfy { $0.correlation?.requestID == invocation.requestID })
        }
        #expect(capture.events.allSatisfy { $0.runID == context.runID && $0.correlation?.sessionID == context.sessionID })
        let requestBody = AgentWireFormat.openAI.requestBody(requests[2], model: "test")
        let replay = requestBody["messages"].array
        let callIDs = replay.flatMap { $0["tool_calls"].array.compactMap { $0["id"].string } }
        let resultIDs = replay.filter { $0["role"].string == "tool" }.compactMap { $0["tool_call_id"].string }
        #expect(callIDs.count == 2 && Set(callIDs).count == 2 && resultIDs == callIDs)
        #expect(results.map(\.invocation.callID) == ["reused", "reused"])
    }

    @Test(arguments: [AgentStreamFailure.preparation, .transport, .invalidStream, .cancelled, .deferred])
    func failuresProduceNativeAuditEvenBeforeFirstBlock(failure: AgentStreamFailure) async throws {
        struct Model: AgentModel {
            let failure: AgentStreamFailure
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                onEvent(.content(.failed(failure)))
                throw AgentWireError.invalidResponse
            }
        }
        var events: [AgentEvent] = []
        let capture = DiagnosticCapture()
        do {
            let harness = NativeHarness(model: Model(failure: failure), diagnosticSink: { capture.record($0) })
            for try await event in harness.run(systemPrompt: "", history: [], prompt: "Question", tools: []) { events.append(event) }
            Issue.record("Expected failure")
        } catch { }
        let request = try #require(events.compactMap { if case .requestStarted(let value) = $0 { return value }; return nil }.first)
        let final = try #require(events.compactMap { if case .messageAppended(.content(let value)) = $0, value.role == .assistant { return value }; return nil }.first)
        #expect(final.identity?.requestID == request.id && final.identity?.api == nil && final.identity?.model == nil)
        #expect(final.stopReason == (failure == .cancelled ? .aborted : failure == .deferred ? .deferred : .error))
        #expect(final.blocks.isEmpty && final.timestampMilliseconds != nil)
        #expect(final.providerMetadata?["failure"] == .string(failure.rawValue))
        #expect(events.filter { if case .modelContent(.failed) = $0 { return true }; return false }.count == 1)
        #expect(capture.events.contains { $0.kind == .requestFailed && $0.metrics[.protocolFailure] == failure.diagnosticCode })
    }

    @Test func partialFailurePreservesRawCallsButNeverExecutesThem() async throws {
        struct Model: AgentModel {
            var descriptor: AgentModelDescriptor? { AgentModelDescriptor(api: "anthropic", model: "test") }
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                onEvent(.content(.blockStarted(index: 0, block: AgentContentBlock(id: "partial", content: .toolCall(agentCall(raw: "{private"), complete: false)))))
                throw AgentWireError.incompleteStream
            }
        }
        var events: [AgentEvent] = []
        do {
            let tool = AgentTool(spec: agentTool().spec) { _ in Issue.record("Partial call executed"); return AgentToolOutput(content: "", summary: "") }
            for try await event in NativeHarness(model: Model()).run(systemPrompt: "", history: [], prompt: "Question", tools: [tool]) { events.append(event) }
        } catch { }
        let assistant = try #require(events.compactMap { if case .messageAppended(.content(let value)) = $0, value.role == .assistant { return value }; return nil }.first)
        let result = try #require(events.compactMap { if case .messageAppended(.tool(let value)) = $0 { return value }; return nil }.first)
        #expect(assistant.stopReason == .error && assistant.toolCalls.first?.rawArguments == "{private")
        #expect(assistant.identity?.api == "anthropic")
        #expect(result.invocation.id == assistant.toolCalls.first?.invocationID)
        #expect(result.invocation.requestID == assistant.identity?.requestID)
        #expect(result.isError && result.syntheticReason == .interruptedResponse)
        let diagnostics = events.compactMap { if case .diagnostic(let value) = $0 { return value.logLine }; return nil }.joined()
        #expect(!diagnostics.contains("private"))
        #expect(!events.contains { if case .toolStarted = $0 { return true }; return false })
    }

    @Test func namespacedCallCannotDispatchToUnqualifiedBuiltin() async throws {
        let call = AgentToolCall(id: "call", name: "lookup", arguments: .object([:]), rawArguments: "{}", namespace: "external")
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [call]), AgentTurnResponse(text: "Unsupported")])
        let tool = AgentTool(spec: agentTool().spec) { _ in Issue.record("Namespace bypass"); return AgentToolOutput(content: "", summary: "") }
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model), tools: [tool]))
        guard case .tool(let result) = outcome.messages[2] else { Issue.record("Missing native error"); return }
        #expect(result.invocation.namespace == "external" && result.syntheticReason == .unsupportedNamespace && result.isError)
    }

    @Test(arguments: AgentWireFormat.allCases)
    func failedMessagesAndTheirResultsStayOutOfReplay(format: AgentWireFormat) throws {
        let request = try AgentRequestIdentity(id: "failed")
        let failed = try AgentMessageFactory.failure(.cancelled,
            blocks: [AgentContentBlock(id: "partial", content: .toolCall(agentCall(), complete: false))], request: request, descriptor: nil)
        let invocation = try AgentMessageFactory.invocation(failed.toolCalls[0], requestID: request.id)
        let result = try AgentMessageFactory.result(invocation, output: AgentToolOutput(content: "Do not replay", summary: ""),
            isError: true, syntheticReason: .interruptedResponse)
        let history: [AgentMessage] = [.user("Question"), .content(failed), result, .user("Retry")]
        let projection = format.requestProjection(AgentTurnRequest(systemPrompt: "", messages: history, tools: [], maxOutputTokens: 32), model: "test")
        #expect(projection.adjustment.omittedMessages == 2)
        #expect(!String(describing: projection.body).contains("Do not replay"))
        #expect(history[1] == .content(failed) && history[2] == result)
    }
}

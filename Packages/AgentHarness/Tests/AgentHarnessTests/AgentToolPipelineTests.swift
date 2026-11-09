import Foundation
import Testing
@testable import AgentHarness

private actor ToolProbe {
    var active = 0
    var maximum = 0
    var executed: [Int] = []
    var context: AgentToolExecutionContext?
    func begin(_ index: Int, context: AgentToolExecutionContext) { active += 1; maximum = max(maximum, active); executed.append(index); self.context = context }
    func end() { active -= 1 }
    func lateProgress() { context?.progress(AgentToolProgress(.committing, completed: 999)) }
}

@Suite struct AgentToolPipelineTests {
    private func tool(_ probe: ToolProbe, scheduling: AgentTool.Scheduling = .parallelRead, output: AgentToolOutput? = nil) -> AgentTool {
        AgentTool(spec: agentTool().spec, scheduling: scheduling, executeWithContext: { arguments, context in
            let index: Int
            if case .object(let fields) = arguments, case .number(let value) = fields["index"] { index = Int(value) } else { index = 0 }
            await probe.begin(index, context: context)
            try await Task.sleep(for: .milliseconds(index == 0 ? 40 : 2))
            context.progress(AgentToolProgress(.executing, completed: index))
            await probe.end()
            return output ?? AgentToolOutput(content: String(index), summary: String(index))
        })
    }

    @Test func boundedReadsCompleteOutOfOrderButAppendInCallOrderAndFenceLateProgress() async throws {
        let probe = ToolProbe()
        let capture = DiagnosticCapture()
        let calls = (0..<6).map { agentCall(String($0), raw: "{\"index\":\($0)}") }
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls), AgentTurnResponse(text: "Done")])
        let events = try await agentEvents(NativeHarness(model: model, maxParallelReads: 2, diagnosticSink: { capture.record($0) }), tools: [tool(probe)])
        #expect(await probe.maximum == 2)
        let finished = events.compactMap { if case .toolFinished(let id, _, _, _) = $0 { return id }; return nil }
        #expect(finished.first == "1" && finished != calls.map(\.id))
        let results = try agentOutcome(events).messages.compactMap { if case .tool(let value) = $0 { return value }; return nil }
        #expect(results.map(\.invocation.callID) == calls.map(\.id))
        let before = capture.events.count
        await probe.lateProgress()
        #expect(capture.events.count == before)
        for result in results {
            let facts = capture.events.filter { $0.correlation?.invocationID == result.invocation.id }
            #expect(facts.first?.kind == .toolRequested && facts.last?.kind == .toolFinished)
            #expect(facts.allSatisfy { $0.correlation?.requestID == result.invocation.requestID })
        }
    }

    @Test func oneSequentialToolSerializesWholeBatch() async throws {
        let probe = ToolProbe()
        let serial = AgentTool(spec: AgentToolSpec(name: "write", description: "", inputSchema: agentTool().spec.inputSchema)) { _ in
            AgentToolOutput(content: "Written", summary: "Written")
        }
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall("0"), agentCall("1"), agentCall("2", name: "write")]), AgentTurnResponse(text: "Done")])
        let events = try await agentEvents(NativeHarness(model: model), tools: [tool(probe), serial])
        #expect(await probe.maximum == 1)
        let lifecycle = events.compactMap { event -> String? in
            if case .toolStarted(let id, _, _) = event { return "start" + id }
            if case .toolFinished(let id, _, _, _) = event { return "end" + id }; return nil
        }
        #expect(lifecycle == ["start0", "end0", "start1", "end1", "start2", "end2"])
    }

    @Test(arguments: [false, true]) func policyDeniesOrRevalidatesTransformedArguments(transform: Bool) async throws {
        let schema = try JSONValue.parse(#"{"type":"object","properties":{"n":{"type":"integer","maximum":2}},"required":["n"],"additionalProperties":false}"#)
        let tool = AgentTool(spec: AgentToolSpec(name: "lookup", description: "", inputSchema: schema)) { _ in
            Issue.record("Denied or invalid arguments must never execute"); return AgentToolOutput(content: "", summary: "")
        }
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall(raw: #"{"n":1}"#)]), AgentTurnResponse(text: "Done")])
        let events = try await agentEvents(NativeHarness(model: model, toolPolicy: { _, _ in transform ? .allow(.object(["n": .number(3)])) : .deny }), tools: [tool])
        let results = try agentOutcome(events).messages.compactMap { if case .tool(let value) = $0 { return value }; return nil }
        #expect(results.first?.syntheticReason == (transform ? .invalidArguments : .policyDenied))
        #expect(events.contains { if case .diagnostic(let fact) = $0 { return fact.kind == (transform ? .toolValidationFailed : .toolPolicyDenied) }; return false })
    }

    @Test(arguments: [false, true]) func structuredDataSurvivesCodecButNeverEntersProviderReplay(isError: Bool) async throws {
        let probe = ToolProbe()
        let output = AgentToolOutput(content: "Model-visible", summary: "UI summary", isError: isError,
            details: .string("UI_PRIVATE"), structuredContent: .string("STRUCTURED_PRIVATE"))
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()]), AgentTurnResponse(text: "Done")])
        let events = try await agentEvents(NativeHarness(model: model), tools: [tool(probe, output: output)])
        let result = try #require(agentOutcome(events).messages.compactMap { if case .tool(let value) = $0 { return value }; return nil }.first)
        #expect(try JSONDecoder().decode(AgentToolResultMessage.self, from: JSONEncoder().encode(result)) == result)
        #expect(result.structuredContent == output.structuredContent)
        #expect(result.isError == isError)
        let request = try #require(await model.requests.last)
        for format in [AgentWireFormat.openAI, .openAIResponses, .anthropic, .gemini] {
            let bytes = try format.requestBody(request, model: "test").encodedString()
            #expect(bytes.contains("Model-visible") && !bytes.contains("UI_PRIVATE") && !bytes.contains("STRUCTURED_PRIVATE"))
        }
    }

    @Test func cancellationAfterCommittedEffectAcknowledgesSuccessAndStopsNextRequest() async throws {
        let capture = DiagnosticCapture()
        let tool = AgentTool(spec: agentTool().spec, executeWithContext: { _, context in
            context.progress(AgentToolProgress(.committed))
            withUnsafeCurrentTask { $0?.cancel() }
            return AgentToolOutput(content: "Committed", summary: "Committed", metrics: [.mutationsCommitted: 1])
        })
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()]), AgentTurnResponse(text: "Must not request")])
        let task = Task { () -> [AgentEvent] in
            var events: [AgentEvent] = []
            do {
                for try await event in NativeHarness(model: model, diagnosticSink: { capture.record($0) })
                    .run(systemPrompt: "", history: [], prompt: "", tools: [tool]) { events.append(event) }
                Issue.record("Expected cancellation")
            } catch { #expect(error is CancellationError) }
            return events
        }
        let events = await task.value
        #expect(events.contains { if case .toolFinished(_, _, "Committed", false) = $0 { return true }; return false })
        #expect(capture.events.contains { $0.kind == .toolFinished && $0.metrics[.mutationsCommitted] == 1 && $0.metrics[.isError] == 0 })
        #expect(await model.requests.count == 1)
    }
}

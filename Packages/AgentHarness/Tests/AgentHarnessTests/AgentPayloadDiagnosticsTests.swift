import Testing
@testable import AgentHarness

struct AgentPayloadDiagnosticsTests {
    @Test func clippingAndContinuationAreDistinctFacts() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()]), AgentTurnResponse(text: "Answer")])
        let tool = AgentTool(spec: AgentToolSpec(name: "lookup", description: "Read", inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(true)]))) { _ in
            AgentToolOutput(content: "PRIVATE TEXT", summary: "Read", metrics: [.omittedScalars: 7, .deferredScalars: 20])
        }
        let events = try await agentEvents(NativeHarness(model: model), tools: [tool])
        let trace = events.compactMap { if case .diagnostic(let value) = $0 { return value }; return nil }
        #expect(trace.filter { $0.kind == .payloadClipped }.first?.metrics[.omittedScalars] == 7)
        #expect(trace.filter { $0.kind == .payloadPaged }.first?.metrics[.deferredScalars] == 20)
        #expect(!trace.map(\.logLine).joined().contains("PRIVATE TEXT"))
    }

    @Test func summaryRecordsToolSerializationAndHistoryFittingSeparately() throws {
        let compactor = AgentContextCompactor(policy: AgentContextPolicy(contextWindow: 1_000))
        let plan = AgentCompactionPlan(previousSummary: nil,
            messagesToSummarize: [.toolResult(callID: "1", toolName: "lookup", content: String(repeating: "中", count: 5_000), isError: false)],
            turnPrefix: [], kept: [])
        let request = try #require(compactor.historySummaryRequest(for: plan))
        #expect(request.serializedToolOmittedCharacters == 3_000)
        #expect(request.fittedHistoryOmittedCharacters > 0)
        #expect(request.contextOmittedCharacters == request.serializedToolOmittedCharacters + request.fittedHistoryOmittedCharacters)
    }
}

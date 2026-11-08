import Foundation
import Testing
@testable import AgentHarness

private final class DiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentDiagnostic] = []
    func record(_ value: AgentDiagnostic) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var events: [AgentDiagnostic] { lock.lock(); defer { lock.unlock() }; return values }
}

struct AgentDiagnosticTests {
    @Test func blockedBatchRecordsOneLimitAndEverySkippedCallEvenWithAFinalAnswer() async throws {
        let calls = (1...61).map { agentCall(String($0)) }
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls),
                                       AgentTurnResponse(text: "Partial answer", stopReason: .maxTokens)])
        let capture = DiagnosticCapture()
        let harness = NativeHarness(model: model, limits: AgentLimits(maxTurns: 14, maxToolCalls: 51, wrapUpOnLimit: true),
                                    diagnosticSink: { capture.record($0) })
        let events = try await agentEvents(harness, tools: [agentTool()])
        let diagnostics = capture.events
        #expect(diagnostics.filter { $0.kind == .limitReached }.map(\.stopReason) == [.toolCallLimit])
        #expect(diagnostics.filter { $0.kind == .toolSkipped }.count == 10)
        #expect(diagnostics.filter { $0.kind == .toolFinished }.count == 61)
        #expect(diagnostics.first { $0.kind == .limitReached }?.metrics[.toolCalls] == 51)
        #expect(diagnostics.filter { $0.kind == .toolSkipped }.compactMap { $0.metrics[.callOrdinal] } == Array(52...61))
        #expect(diagnostics.contains { $0.kind == .wrapUpStarted })
        #expect(diagnostics.contains { $0.kind == .wrapUpFinished && $0.stopReason == .outputLimit })
        #expect(try agentOutcome(events).finalText == "Partial answer")
        #expect(try agentOutcome(events).stopReason == .outputLimit)
        #expect(diagnostics.last?.kind == .runFinished)
        #expect(diagnostics.map(\.sequence) == Array(1...diagnostics.count))
        #expect(Set(diagnostics.map(\.runID)).count == 1)
        let replay = try #require(await model.requests.last)
        #expect(!replay.allowsToolCalls)
        #expect(replay.messages.filter { if case .toolResult(_, _, _, false) = $0 { return true }; return false }.count == 51)
    }

    @Test func capacitySnapshotPrecedesContextCheckAndEveryRequestSharesItsIdentity() async throws {
        let resolution = AgentContextResolution(contextWindowTokens: 1_050_000, source: .fixedTable, reason: .catalogMatch)
        let harness = NativeHarness(model: ScriptedAgentModel([AgentTurnResponse(text: "Answer")]),
                                    contextPolicy: AgentContextPolicy(contextWindow: resolution.contextWindowTokens))
        var events: [AgentEvent] = []
        for try await event in harness.run(systemPrompt: "System", history: [.user(String(repeating: "a", count: 132_000))],
                                           prompt: "Question", tools: [], maxOutputTokens: 512, contextResolution: resolution) {
            events.append(event)
        }
        #expect(events[1] == .contextResolved(resolution))
        let diagnostics = events.compactMap { if case .diagnostic(let value) = $0 { return value }; return nil }
        #expect(diagnostics.allSatisfy { $0.resolutionID == resolution.id })
        #expect(!diagnostics.contains { $0.kind == .compactionStarted })
        #expect(diagnostics.contains { $0.kind == .contextCheck && ($0.metrics[.thresholdTokens] ?? 0) > 33_000 })
        #expect(diagnostics.filter { $0.kind == .requestStarted }.count == 1)
        #expect(diagnostics.filter { $0.kind == .requestFinished }.count == 1)
        let encoded = try JSONEncoder().encode(diagnostics)
        #expect(try JSONDecoder().decode([AgentDiagnostic].self, from: encoded) == diagnostics)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("Question"))
    }

    @Test func providerFailureHasAnIndependentTerminalDiagnostic() async {
        let capture = DiagnosticCapture()
        let harness = NativeHarness(model: ScriptedAgentModel([], fails: true), diagnosticSink: { capture.record($0) })
        await #expect(throws: ScriptedAgentModel.Failure.provider) { try await agentEvents(harness) }
        #expect(capture.events.last?.kind == .runFailed)
        #expect(capture.events.contains { $0.kind == .requestFailed })
        #expect(!capture.events.contains { $0.kind == .runFinished })
    }

    @Test func logVocabularyContainsOnlyStructuredFacts() {
        let event = AgentDiagnostic(runID: UUID(), sequence: 3, kind: .limitReached,
                                    metrics: [.toolCalls: 51, .maxToolCalls: 51], stopReason: .toolCallLimit,
                                    resolutionID: UUID())
        #expect(event.logLine.contains("reason=toolCallLimit"))
        #expect(event.logLine.contains("maxToolCalls=51"))
        #expect(event.logLine.contains("resolution="))
    }
}

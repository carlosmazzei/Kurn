import Foundation
import Testing
@testable import AgentHarness

struct AgentNativeFailureTests {
    @Test func incomingLocalIdentitiesCannotBeReusedByAnAdapter() async throws {
        actor Model: AgentModel {
            var calls = 0
            func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
                calls += 1
                let call = AgentToolCall(id: "repeated", name: "lookup", arguments: .object([:]), rawArguments: "{}", invocationID: "untrusted-local-id")
                let message = try AgentContentMessage(id: "repeated-message", timestampMilliseconds: nil, role: .assistant,
                    blocks: calls <= 2 ? [AgentContentBlock(id: "call", content: .toolCall(call, complete: true))] : [],
                    identity: AgentResponseIdentity(requestID: try #require(request.identity?.id)), stopReason: calls <= 2 ? .toolUse : .endTurn)
                return AgentTurnResponse(text: "", message: message)
            }
        }
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: Model()), tools: [agentTool()]))
        let assistants = outcome.messages.compactMap { if case .content(let value) = $0, value.role == .assistant { return value }; return nil }
        #expect(Set(assistants.map(\.id)).count == 3 && !assistants.contains { $0.id == "repeated-message" })
        let calls = assistants.flatMap(\.toolCalls)
        #expect(Set(calls.compactMap(\.invocationID)).count == 2 && !calls.contains { $0.invocationID == "untrusted-local-id" })
    }

    @Test func failureAuditRetainsNonObjectOpaqueCallMetadata() throws {
        let raw: JSONValue = .array([.string("opaque=="), .object(["future": .bool(true)])])
        let call = AgentToolCall(id: "call", name: "lookup", arguments: .null, rawArguments: "{private", providerMetadata: raw)
        let message = try AgentMessageFactory.failure(.transport,
            blocks: [AgentContentBlock(id: "call", content: .toolCall(call, complete: false))],
            request: AgentRequestIdentity(), descriptor: nil)
        #expect(message.toolCalls.first?.providerMetadata?["originalProviderMetadata"] == raw)
        #expect(message.toolCalls.first?.rawArguments == "{private")
    }

    @Test func oversizedToolOutputStillClosesCorrelatedDiagnostics() async throws {
        let capture = DiagnosticCapture()
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()])])
        let tool = AgentTool(spec: agentTool().spec) { _ in
            AgentToolOutput(content: String(repeating: "x", count: 8 * 1_024 * 1_024), summary: "Oversized")
        }
        await #expect(throws: AgentContentError.invalidMessage) {
            try await agentEvents(NativeHarness(model: model, diagnosticSink: { capture.record($0) }), tools: [tool])
        }
        let finished = try #require(capture.events.first { $0.kind == .toolFinished })
        #expect(finished.metrics[.isError] == 1 && finished.correlation?.invocationID != nil)
        #expect(finished.metrics[.protocolFailure] == AgentStreamFailure.invalidStream.diagnosticCode)
    }
}

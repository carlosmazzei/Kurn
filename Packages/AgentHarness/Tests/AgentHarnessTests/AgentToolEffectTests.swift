import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentToolEffectTests {
    private func tool(_ name: String, effect: AgentTool.Effect, confirmation: Bool? = nil,
                      terminates: Bool = false, scheduling: AgentTool.Scheduling = .sequential) -> AgentTool {
        AgentTool(spec: AgentToolSpec(name: name, description: name, inputSchema: .object(["type": .string("object"),
            "properties": .object([:]), "additionalProperties": .bool(true)])),
            effect: effect, requiresConfirmation: confirmation, scheduling: scheduling) { _ in
            AgentToolOutput(content: name, summary: name, terminatesRun: terminates)
        }
    }

    @Test func destructiveToolsAskByDefaultAndOthersDoNot() {
        #expect(!tool("r", effect: .read).requiresConfirmation)
        #expect(!tool("w", effect: .write).requiresConfirmation)
        #expect(tool("d", effect: .destructive).requiresConfirmation)
        #expect(!tool("d", effect: .destructive, confirmation: false).requiresConfirmation)
        #expect(tool("w", effect: .write, confirmation: true).requiresConfirmation)
        #expect(agentTool().effect == .read)
    }

    @Test func approvedDestructiveCallRunsAndTheRunContinues() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall(name: "replace")]),
                                        AgentTurnResponse(text: "Replaced")])
        let asked = Asked()
        let harness = NativeHarness(model: model, confirm: { call in await asked.record(call.name); return true })
        let outcome = try agentOutcome(try await agentEvents(harness, tools: [tool("replace", effect: .destructive)]))
        #expect(outcome.stopReason == .completed)
        #expect(outcome.finalText == "Replaced")
        #expect(await asked.names == ["replace"])
    }

    @Test func declinedCallEndsTheRunAndSkipsTheRestOfItsBatch() async throws {
        let calls = [agentCall("1", name: "replace"), agentCall("2", name: "note")]
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Replacing", toolCalls: calls), AgentTurnResponse(text: "Never")])
        let diagnostics = DiagnosticCapture()
        let harness = NativeHarness(model: model, confirm: { _ in false }, diagnosticSink: { diagnostics.record($0) })
        let events = try await agentEvents(harness, tools: [tool("replace", effect: .destructive), tool("note", effect: .write)])
        let outcome = try agentOutcome(events)
        #expect(outcome.stopReason == .terminated)
        #expect(await model.requests.count == 1)
        let results = outcome.messages.compactMap { message -> (String, Bool)? in
            if case .toolResult(let id, _, _, let isError) = message.legacyProjection { return (id, isError) }
            return nil
        }
        // Every call keeps a result: the declined one and the one never run.
        #expect(results.map(\.0) == ["1", "2"])
        #expect(results.map(\.1) == [true, true])
        #expect(events.contains(.toolFinished(callID: "2", name: "note", summary: "Tool not executed: the run was ended.", isError: true)))
        let kinds = diagnostics.events.map(\.kind)
        #expect(kinds.contains(.runTerminated))
        #expect(!kinds.contains(.limitReached))
    }

    @Test func aToolCanEndTheRun() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Done here", toolCalls: [agentCall(name: "finish")]),
                                        AgentTurnResponse(text: "Never")])
        let harness = NativeHarness(model: model, limits: AgentLimits(wrapUpOnLimit: true))
        let outcome = try agentOutcome(try await agentEvents(harness, tools: [tool("finish", effect: .read, terminates: true)]))
        #expect(outcome.stopReason == .terminated)
        #expect(outcome.finalText == "Done here")
        #expect(await model.requests.count == 1)
    }

    @Test func aParallelReadBatchFinishesBeforeTheRunEnds() async throws {
        let calls = [agentCall("1", name: "finish"), agentCall("2", name: "read")]
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls), AgentTurnResponse(text: "Never")])
        let outcome = try agentOutcome(try await agentEvents(NativeHarness(model: model), tools: [
            tool("finish", effect: .read, terminates: true, scheduling: .parallelRead),
            tool("read", effect: .read, scheduling: .parallelRead)]))
        #expect(outcome.stopReason == .terminated)
        #expect(await model.requests.count == 1)
        let errors = outcome.messages.compactMap { message -> Bool? in
            if case .toolResult(_, _, _, let isError) = message.legacyProjection { return isError }
            return nil
        }
        #expect(errors == [false, false])
    }

    @Test func outputCodingKeepsOlderBytes() throws {
        let plain = AgentToolOutput(content: "c", summary: "s")
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!encoded.contains("terminatesRun"))
        #expect(try JSONDecoder().decode(AgentToolOutput.self, from: Data(encoded.utf8)) == plain)
        let ending = AgentToolOutput(content: "c", summary: "s", details: .string("d"), structuredContent: .bool(true), terminatesRun: true)
        #expect(try JSONDecoder().decode(AgentToolOutput.self, from: JSONEncoder().encode(ending)) == ending)
    }
}

private actor Asked {
    var names: [String] = []
    func record(_ name: String) { names.append(name) }
}

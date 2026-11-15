import Foundation
import Testing
@testable import AgentHarness

/// A run's canonical record read back from the log (NH06): what entered its model context, and
/// whether it answered.
@Suite struct AgentRunBranchTests {
    private func record(_ responses: [AgentTurnResponse], fails: Bool = false,
                        commandID: String? = nil) async throws -> [AgentSessionEntry] {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let run = try await session.start(harness: NativeHarness(model: ScriptedAgentModel(responses, fails: fails)),
                                          systemPrompt: "", history: [], prompt: "Q", tools: [agentTool()],
                                          commandID: commandID, startFields: ["host": .string("value")])
        do { for try await _ in run.events {} } catch {}
        _ = await session.waitUntilSettled()
        return await store.entries
    }

    @Test func aCompletedRunReplaysItsRequestCallsResultsAndAnswer() async throws {
        let entries = try await record([AgentTurnResponse(text: "", toolCalls: [agentCall("call-1")]),
                                        AgentTurnResponse(text: "Answer")], commandID: "command")
        let run = try #require(AgentRunBranch.all(in: entries).first)

        #expect(AgentRunBranch.all(in: entries).count == 1)
        #expect(run.entries.first?.kind == AgentRunBranch.startType)
        #expect(run.startFields["host"] == .string("value"))
        #expect(run.startFields["commandID"] == .string("command"))
        #expect(run.end == "completed")
        let messages = run.contextMessages
        #expect(messages.count == 4)
        guard case .content(let request)? = messages.first, case .content(let call)? = messages.dropFirst().first,
              case .tool(let result)? = messages.dropFirst(2).first else {
            Issue.record("Expected request, call and result")
            return
        }
        #expect(request.role == .user && request.text == "Q")
        #expect(call.toolCalls.map(\.id) == ["call-1"])
        #expect(result.invocation.callID == "call-1")
        #expect(run.answer?.text == "Answer")
    }

    @Test func aReplyCutOffByTheOutputLimitNeverReplays() async throws {
        let entries = try await record([AgentTurnResponse(text: "Partial", toolCalls: [agentCall("call-1")],
                                                          stopReason: .maxTokens)])
        let run = try #require(AgentRunBranch.all(in: entries).first)

        // The interrupted reply is in the log as an audit record, never in the replayed context.
        #expect(entries.contains {
            if case .message(.content(let message)) = $0.payload { return message.stopReason == .maxTokens }
            return false
        })
        #expect(run.contextMessages.count == 1)
        #expect(run.answer == nil)
    }

    @Test func aFailedRunHasNoAnswer() async throws {
        let entries = try await record([], fails: true)
        let run = try #require(AgentRunBranch.all(in: entries).first)

        #expect(run.end == "failed")
        #expect(run.answer == nil)
    }

    @Test func anOpenRunHasNoEndAndNoAnswer() async throws {
        let entries = try await record([AgentTurnResponse(text: "Answer")])
        let open = entries.filter { $0.kind != AgentRunBranch.endType }
        let run = try #require(AgentRunBranch.all(in: open).first)

        #expect(run.end == nil)
        #expect(run.answer == nil)
        // The host's own entry belongs to no run, and a run without its start is not read.
        #expect(AgentRunBranch.all(in: open.filter { $0.kind != AgentRunBranch.startType }).isEmpty)
    }
}

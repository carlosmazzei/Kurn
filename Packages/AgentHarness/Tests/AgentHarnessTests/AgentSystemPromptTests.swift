import Foundation
import Testing
@testable import AgentHarness

/// NH06 system sections and tool loadouts: each run records its system prompt as a patch on the
/// previous run's and its declared tools with their delta.
@Suite struct AgentSystemPromptTests {
    private func prompt(_ sections: [(String, String)]) throws -> AgentSystemPrompt {
        try AgentSystemPrompt(sections: sections.map { .init(name: $0.0, text: $0.1) })
    }

    private func tool(_ name: String) -> AgentTool {
        AgentTool(spec: AgentToolSpec(name: name, description: "Tool", inputSchema: agentTool().spec.inputSchema)) { _ in
            AgentToolOutput(content: "ok", summary: "ok")
        }
    }

    @Test func aPatchChangesOnlyTheSectionsItNamesAndNullRemovesOne() throws {
        let base = try prompt([("identity", "You help."), ("rules", "Cite."), ("documents", "[]")])
        let next = try prompt([("identity", "You help."), ("rules", "Cite."), ("documents", "[1]"), ("scope", "One meeting")])
        let patch = base.patch(to: next)

        #expect(patch.changes == [.init(name: "documents", text: "[1]"), .init(name: "scope", text: "One meeting")])
        #expect(base.applying(patch) == next)
        #expect(next.text == "You help.\n\nCite.\n\n[1]\n\nOne meeting")
        // Removing a section is an explicit null, which survives the JSON round trip.
        let removal = next.patch(to: try prompt([("identity", "You help."), ("documents", "[1]"), ("scope", "One meeting")]))
        #expect(removal.changes == [.init(name: "rules", text: nil)])
        let encoded = String(decoding: try JSONEncoder().encode(removal), as: UTF8.self)
        #expect(encoded.contains("\"text\":null"))
        let decoded = try JSONDecoder().decode(AgentSystemPatch.self, from: Data(encoded.utf8))
        #expect(next.applying(decoded).sections.map(\.name) == ["identity", "documents", "scope"])
        #expect(base.patch(to: base).isEmpty)
        #expect(throws: AgentSessionStoreError.invalidEntry) { try prompt([("a", "1"), ("a", "2")]) }
    }

    @Test func eachRunRecordsItsPromptPatchAndToolDelta() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let prompts = [
            try prompt([("identity", "You help."), ("documents", "[]")]),
            try prompt([("identity", "You help."), ("documents", "[1]")]),
            try prompt([("identity", "You help.")])
        ]
        let loadouts = [[tool("lookup"), tool("search")], [tool("search"), tool("write")], [tool("search"), tool("write")]]
        for (system, tools) in zip(prompts, loadouts) {
            let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
            let run = try await session.start(harness: NativeHarness(model: model), systemPrompt: "ignored", history: [],
                                              prompt: "Q", tools: tools, system: system)
            do { for try await _ in run.events {} } catch {}
            #expect(await session.waitUntilSettled().end == .completed)
            // The model receives the sections' text.
            #expect(await model.requests.first?.systemPrompt == system.text)
        }
        let runs = AgentRunBranch.all(in: await store.entries)
        #expect(runs.count == 3)

        // The first run records its whole prompt; the next ones only what changed.
        #expect(runs[0].startFields["system"] != nil && runs[0].startFields["systemPatch"] == nil)
        #expect(AgentRunBranch.decode(AgentSystemPatch.self, runs[1].startFields["systemPatch"])?.changes
            == [.init(name: "documents", text: "[1]")])
        #expect(AgentRunBranch.decode(AgentSystemPatch.self, runs[2].startFields["systemPatch"])?.changes
            == [.init(name: "documents", text: nil)])
        #expect(AgentRunBranch.systemPrompts(of: runs) == prompts)

        // Each run's declared tools, and what changed since the run before.
        #expect(runs.compactMap(\.toolLoadout).map(\.names) == [["lookup", "search"], ["search", "write"], ["search", "write"]])
        #expect(runs[0].toolLoadout?.added == ["lookup", "search"])
        #expect(runs[1].toolLoadout?.added == ["write"])
        #expect(runs[1].toolLoadout?.removed == ["lookup"])
        #expect(runs[2].toolLoadout?.added == [] && runs[2].toolLoadout?.removed == [])
    }

    @Test func aPatchWithNothingToApplyToIsUnknown() throws {
        let entry = try AgentSessionEntry(sessionID: "s", id: "start", parentID: nil, ordinal: 1, createdAt: AgentSessionEntry.time(),
            payload: .custom(type: AgentRunBranch.startType, data: .object([
                "systemPatch": .object(["changes": .array([.object(["name": .string("a"), "text": .string("x")])])])
            ])), metadata: .object(["runID": .string("run")]))
        let run = try #require(AgentRunBranch.all(in: [entry]).first)
        #expect(run.systemPrompt(after: nil) == nil)
        let previous = try prompt([("a", "old"), ("b", "kept")])
        let expected = try prompt([("a", "x"), ("b", "kept")])
        #expect(run.systemPrompt(after: previous) == expected)
        #expect(run.toolLoadout == nil)
    }

    /// A tool that changes what the prompt describes is seen by the next request of the same run;
    /// an unchanged or missing refresh keeps the prompt and records nothing.
    @Test func theNextRequestSeesAPromptChangedByATool() async throws {
        actor Index {
            var version = 1
            func bump() { version += 1 }
            func prompt() -> String { "Be helpful\nDocuments v\(version)" }
        }
        let index = Index()
        let tool = AgentTool(spec: AgentToolSpec(name: "lookup", description: "Changes the index",
                                                 inputSchema: .object(["type": .string("object"), "properties": .object([:]),
                                                                       "additionalProperties": .bool(true)]))) { _ in
            await index.bump()
            return AgentToolOutput(content: "done", summary: "Index changed")
        }
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("1")]),
            AgentTurnResponse(text: "", toolCalls: [agentCall("2")]),
            AgentTurnResponse(text: "Answer")
        ])
        let capture = DiagnosticCapture()
        let harness = NativeHarness(model: model, diagnosticSink: { capture.record($0) }).refreshingSystemPrompt {
            await index.prompt()
        }
        var events: [AgentEvent] = []
        for try await event in harness.run(systemPrompt: "Be helpful\nDocuments v1", history: [], prompt: "Q",
                                           tools: [tool], maxOutputTokens: 256) { events.append(event) }
        let refreshes = capture.events.filter { $0.kind == .systemPromptRefreshed }.count

        #expect(try agentOutcome(events).finalText == "Answer")
        let prompts = await model.requests.map(\.systemPrompt)
        #expect(prompts == ["Be helpful\nDocuments v1", "Be helpful\nDocuments v2", "Be helpful\nDocuments v3"])
        #expect(refreshes == 2)

        // Nothing to refresh: the prompt stays as the run started.
        let plain = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall("1")]), AgentTurnResponse(text: "Answer")])
        for try await _ in NativeHarness(model: plain).refreshingSystemPrompt({ nil }).run(
            systemPrompt: "Fixed", history: [], prompt: "Q", tools: [agentTool()], maxOutputTokens: 256) {}
        #expect(await plain.requests.map(\.systemPrompt) == ["Fixed", "Fixed"])
    }
}

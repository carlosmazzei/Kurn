import Foundation
import Testing
@testable import AgentHarness

/// NH08 queued input: steering after a complete tool batch, follow-ups once the run would finish,
/// one/all modes, and every change saved before it is acknowledged.
@Suite struct AgentInputQueueTests {
    struct DiskFull: Error {}

    /// A tool that queues input while it runs, as a person typing during the call would.
    private func queuingTool(_ queue: AgentInputQueue, _ text: String, as kind: AgentInputQueue.Kind,
                             name: String = "lookup") -> AgentTool {
        AgentTool(spec: AgentToolSpec(name: name, description: "Tool", inputSchema: agentTool().spec.inputSchema),
                  scheduling: .parallelRead) { _ in
            try await queue.enqueue(text, as: kind)
            return AgentToolOutput(content: "result of \(name)", summary: "ok")
        }
    }

    private func lastUserTexts(_ request: AgentTurnRequest) -> [String] {
        request.messages.reversed().prefix { message in
            if case .content(let value) = message { return value.role == .user }
            return false
        }.reversed().compactMap { message in
            if case .content(let value) = message { return value.text }
            return nil
        }
    }

    @Test func steeringEntersAfterTheWholeToolBatchBeforeTheNextRequest() async throws {
        let queue = AgentInputQueue()
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("1", name: "first"), agentCall("2", name: "second")]),
            AgentTurnResponse(text: "Done")
        ])
        let tools = [queuingTool(queue, "Focus on Monday", as: .steering, name: "first"),
                     AgentTool(spec: AgentToolSpec(name: "second", description: "Tool", inputSchema: agentTool().spec.inputSchema),
                               scheduling: .parallelRead) { _ in AgentToolOutput(content: "result of second", summary: "ok") }]
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model).receivingInput(queue), tools: tools))

        #expect(outcome.finalText == "Done")
        let requests = await model.requests
        #expect(requests.count == 2)
        // Both results come before the steering message, which is the last thing the next request sees.
        let second = requests[1].messages
        let results = second.enumerated().filter { if case .tool = $0.element { return true }; return false }.map(\.offset)
        #expect(results.count == 2)
        #expect(lastUserTexts(requests[1]) == ["Focus on Monday"])
        #expect(results.allSatisfy { $0 < second.count - 1 })
        #expect(await queue.snapshot.isEmpty)
    }

    @Test func aFollowUpWaitsUntilTheRunWouldFinish() async throws {
        let queue = AgentInputQueue()
        let model = ScriptedAgentModel([
            AgentTurnResponse(text: "", toolCalls: [agentCall("1")]),
            AgentTurnResponse(text: "First answer"),
            AgentTurnResponse(text: "Second answer")
        ])
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model).receivingInput(queue),
                                                         tools: [queuingTool(queue, "And Tuesday?", as: .followUp)]))
        let requests = await model.requests

        #expect(requests.count == 3)
        // Not injected after the tool batch: the second request ends with the tool result.
        if case .tool? = requests[1].messages.last {} else { Issue.record("The follow-up entered too early") }
        #expect(lastUserTexts(requests[2]) == ["And Tuesday?"])
        #expect(outcome.finalText == "Second answer")
    }

    @Test(arguments: [AgentInputQueue.Mode.one, .all])
    func modesDrainOneOrAll(mode: AgentInputQueue.Mode) async throws {
        let queue = AgentInputQueue(followUpMode: mode)
        try await queue.enqueue("A", as: .followUp)
        try await queue.enqueue("B", as: .followUp)
        let model = ScriptedAgentModel((0..<3).map { AgentTurnResponse(text: "Answer \($0)") })
        _ = try agentOutcome(await agentEvents(NativeHarness(model: model).receivingInput(queue)))
        let requests = await model.requests

        if mode == .one {
            #expect(requests.count == 3)
            #expect(lastUserTexts(requests[1]) == ["A"])
            #expect(lastUserTexts(requests[2]) == ["B"])
        } else {
            #expect(requests.count == 2)
            #expect(lastUserTexts(requests[1]) == ["A", "B"])
        }
    }

    @Test func steeringIsTakenBeforeAFollowUpWhenBothWait() async throws {
        let queue = AgentInputQueue()
        try await queue.enqueue("Later", as: .followUp)
        try await queue.enqueue("Now", as: .steering)
        let model = ScriptedAgentModel((0..<3).map { AgentTurnResponse(text: "Answer \($0)") })
        _ = try agentOutcome(await agentEvents(NativeHarness(model: model).receivingInput(queue)))
        let requests = await model.requests
        #expect(lastUserTexts(requests[1]) == ["Now"])
        #expect(lastUserTexts(requests[2]) == ["Later"])
    }

    @Test func drainedItemsAreCommittedAsUserMessagesWithTheirIdentity() async throws {
        let queue = AgentInputQueue()
        let item = try await queue.enqueue("Later", as: .followUp)
        let committed = Committed()
        let model = ScriptedAgentModel([AgentTurnResponse(text: "One"), AgentTurnResponse(text: "Two")])
        let harness = NativeHarness(model: model).receivingInput(queue).persistingMessages { await committed.add($0) }
        _ = try agentOutcome(await agentEvents(harness))
        #expect(await committed.ids.contains(item.id))
    }

    @Test func everyChangeIsSavedBeforeItIsAcknowledged() async throws {
        let saved = Saved()
        let queue = AgentInputQueue(persist: { try await saved.save($0) })
        let first = try await queue.enqueue("  First  ", as: .steering)
        #expect(first.text == "First")
        let second = try await queue.enqueue("Second", as: .followUp)
        try await queue.edit(second.id, text: "Second, edited")
        #expect(await saved.last == AgentInputQueue.Snapshot(steering: [first],
            followUp: [AgentInputQueue.Item(id: second.id, kind: .followUp, text: "Second, edited")]))

        // A change that cannot be saved is refused and changes nothing.
        await saved.fail()
        await #expect(throws: DiskFull.self) { try await queue.enqueue("Third", as: .steering) }
        #expect(await queue.snapshot.steering == [first])
        await saved.recover()

        await #expect(throws: AgentInputQueue.QueueError.emptyText) { try await queue.enqueue("   ", as: .steering) }
        await #expect(throws: AgentInputQueue.QueueError.unknownItem) { try await queue.remove("missing") }
        try await queue.remove(first.id)
        // Clearing hands back what was pending, steering first, for the person's draft.
        let restored = try await queue.clear()
        #expect(restored.map(\.text) == ["Second, edited"])
        #expect(await queue.snapshot.isEmpty)
        #expect(await saved.last?.isEmpty == true)
    }

    @Test func updatesCarryTheCompleteLists() async throws {
        let queue = AgentInputQueue()
        var updates = await queue.updates().makeAsyncIterator()
        let initial = await updates.next()
        #expect(initial?.isEmpty == true)
        let item = try await queue.enqueue("A", as: .steering)
        let changed = await updates.next()
        #expect(changed == AgentInputQueue.Snapshot(steering: [item]))
    }

    private func continued(_ harness: NativeHarness, history: [AgentMessage]) async throws -> AgentRunOutcome {
        try await harness.continueRun(systemPrompt: "", history: history, tools: []).result()
    }

    @Test func continuingWithNothingToAnswerFailsWithoutConsumingTheQueue() async throws {
        let queue = AgentInputQueue()
        try await queue.enqueue("Later", as: .followUp)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Unused")])
        await #expect(throws: AgentContinueError.nothingToContinue) {
            _ = try await continued(NativeHarness(model: model).receivingInput(queue), history: [])
        }
        // A finished reply with an empty queue has nothing to continue either.
        await #expect(throws: AgentContinueError.nothingToContinue) {
            _ = try await continued(NativeHarness(model: model), history: [.user("Q"), .assistant(text: "A", toolCalls: [])])
        }
        #expect(await model.requests.isEmpty)
        #expect(await queue.snapshot.followUp.map(\.text) == ["Later"])
    }

    @Test func continuingAnOpenRequestAnswersItWithoutTakingQueuedInput() async throws {
        let queue = AgentInputQueue()
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Answer")])
        let outcome = try await continued(NativeHarness(model: model).receivingInput(queue), history: [.user("Open question")])
        #expect(outcome.finalText == "Answer")
        #expect(await model.requests.first?.messages.last == .user("Open question"))
    }

    @Test func continuingAfterAReplyTakesOneSelectionWithoutDrainingTwice() async throws {
        let queue = AgentInputQueue()
        try await queue.enqueue("Steer", as: .steering)
        try await queue.enqueue("Follow", as: .followUp)
        let model = ScriptedAgentModel([AgentTurnResponse(text: "One"), AgentTurnResponse(text: "Two")])
        _ = try await continued(NativeHarness(model: model).receivingInput(queue),
                                history: [.user("Q"), .assistant(text: "A", toolCalls: [])])
        let requests = await model.requests
        #expect(requests.count == 2)
        // The continuation took the steering selection only; the follow-up waited for the run's end.
        #expect(lastUserTexts(requests[0]) == ["Steer"])
        #expect(lastUserTexts(requests[1]) == ["Follow"])
        let steering = requests[1].messages.filter {
            if case .content(let value) = $0 { return value.text == "Steer" }
            return false
        }
        #expect(steering.count == 1)
    }

    private actor Saved {
        var last: AgentInputQueue.Snapshot?
        var failing = false
        func save(_ snapshot: AgentInputQueue.Snapshot) throws {
            if failing { throw DiskFull() }
            last = snapshot
        }
        func fail() { failing = true }
        func recover() { failing = false }
    }

    private actor Committed {
        var ids: [String] = []
        func add(_ message: AgentMessage) { if let id = message.canonicalID { ids.append(id) } }
    }
}

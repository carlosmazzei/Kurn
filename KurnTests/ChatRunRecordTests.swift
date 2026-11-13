//
//  ChatRunRecordTests.swift
//  KurnTests
//
//  NH05 persistence barrier and run reconciliation: the question is durable before any request,
//  a run leaves a `.running` record that settles to `.ended`, and a record a dead process left
//  `.running` is marked `.interrupted` at launch with its question reopening as retryable.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatRunRecordTests {
    private static func runRecords(_ session: ChatSession, context: ModelContext) throws -> [ChatRunRecord] {
        try SwiftDataAgentSessionStore(context: context).records(session).compactMap(ChatRunRecord.init)
    }

    @Test func recordsRoundTripAndIgnoreOtherKinds() throws {
        let turn = UUID()
        var run = ChatRunRecord(runID: "run-1", questionTurnID: turn, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        run.state = .interrupted
        let decoded = try #require(ChatRunRecord(run.record()))
        #expect(decoded == run)
        #expect(decoded.startedAt == "2023-11-14T22:13:20.000Z")
        #expect(ChatRunRecord(try AgentRecoveryRecord(id: "e", kind: .effect, data: .object([:]))) == nil)
        #expect(ChatRunRecord(try AgentRecoveryRecord(id: "r", kind: .run, data: .object(["state": .string("unknown")]))) == nil)
    }

    @Test func theQuestionIsSavedAndTheRunRecordedBeforeAnyRequestCompletes() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")], pauseAt: 0)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")

        let session = try #require(vm.pastSessions().first)
        #expect(session.turns.map(\.text) == ["When?"])
        let running = try #require(try Self.runRecords(session, context: context).first)
        #expect(running.state == .running)
        #expect(running.questionTurnID == vm.turns.first?.id)

        for _ in 0..<2_000 where await model.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        vm.cancel()
        await vm.waitUntilSettled()
        #expect(try Self.runRecords(session, context: context).map(\.state) == [.ended])
        #expect(vm.retryableQuestion == "When?")
    }

    @Test func launchRecoveryInterruptsOnlyRunsLeftRunning() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        let store = SwiftDataAgentSessionStore(context: context)
        // A process that died mid-run left this record behind.
        let orphan = ChatRunRecord(runID: "orphan-run", questionTurnID: UUID())
        try store.put(orphan.record(), in: session, expectedRevision: session.canonicalRevision)

        #expect(ChatRunRecovery.sweep(context: context) == 1)
        let states = Dictionary(uniqueKeysWithValues: try Self.runRecords(session, context: context).map { ($0.runID, $0.state) })
        #expect(states["orphan-run"] == .interrupted)
        #expect(states.values.filter { $0 == .ended }.count == 1)
        #expect(ChatRunRecovery.sweep(context: context) == 0)
    }

    @Test func aFailedQuestionSaveSendsNothingAndKeepsTheQuestionRetryable() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        context.delete(meeting)
        try context.save()

        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        #expect(!vm.isResponding)
        #expect(vm.retryableQuestion == "When?")
        let requests = await model.requests
        #expect(requests.isEmpty)
    }
    @Test func aStoreFailureSendsNothingAndTheRetrySavesTheQuestion() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday."), AgentTurnResponse(text: "Tuesday.")])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        let revision = session.canonicalRevision

        // A session the store can no longer validate makes the question's save itself fail.
        session.canonicalRevision = 0
        vm.send(question: "And then?", provider: .openAI, model: "gpt-4o")
        #expect(!vm.isResponding)
        #expect(vm.error != nil)
        #expect(vm.retryableQuestion == "And then?")
        let requestsAfterFailure = await model.requests.count
        #expect(requestsAfterFailure == 1)

        session.canonicalRevision = revision
        vm.error = nil
        vm.dropRetryableQuestion()
        vm.send(question: "And then?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        #expect(vm.turns.map(\.text) == ["When?", "Monday.", "And then?", "Tuesday."])
        #expect(try session.harnessSnapshot().turns.map(\.text) == ["When?", "Monday.", "And then?", "Tuesday."])
    }
    @Test func aReopenedInterruptedQuestionSaysWhyItIsUnanswered() async throws {
        let paused = ChatAgentModel([AgentTurnResponse(text: "Partial")], pauseAt: 0)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let crashed = MeetingChatViewModel(agentModelFactory: { _, _ in paused })
        crashed.configure(meeting: meeting, modelContext: context)
        crashed.send(question: "When?", provider: .openAI, model: "gpt-4o")
        let session = try #require(crashed.pastSessions().first)
        // The process dies here: its run record stays `.running` until the next launch's sweep.
        #expect(ChatRunRecovery.sweep(context: context) == 1)
        let questionID = try #require(session.turns.first?.id)
        #expect(ChatRunRecovery.interruptedQuestionIDs(in: session, context: context) == [questionID])

        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let reopened = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        reopened.configure(meeting: meeting, modelContext: context)
        reopened.load(session: session)
        #expect(reopened.retryableQuestion == "When?")
        #expect(reopened.retryableQuestionWasInterrupted)

        reopened.dropRetryableQuestion()
        #expect(!reopened.retryableQuestionWasInterrupted)
        reopened.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await reopened.waitUntilSettled()
        #expect(reopened.turns.map(\.text) == ["When?", "Monday."])
        #expect(!reopened.retryableQuestionWasInterrupted)
        reopened.reset()
        #expect(!reopened.retryableQuestionWasInterrupted)

        crashed.cancel()
        await crashed.waitUntilSettled()
    }

    @Test func aReopenedInterruptedQuestionShowsWhatItsRunHadDone() async throws {
        // The run reads its sources, then the process dies while the model writes the answer.
        let paused = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources", id: "call-1")]),
            AgentTurnResponse(text: "Partial")
        ], pauseAt: 1)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let crashed = MeetingChatViewModel(agentModelFactory: { _, _ in paused })
        crashed.configure(meeting: meeting, modelContext: context)
        crashed.send(question: "When?", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where await paused.requests.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        let session = try #require(crashed.pastSessions().first)
        #expect(ChatRunRecovery.sweep(context: context) == 1)
        let revision = session.canonicalRevision

        let reopened = MeetingChatViewModel(agentModelFactory: { _, _ in ChatAgentModel() })
        reopened.configure(meeting: meeting, modelContext: context)
        reopened.load(session: session)
        #expect(reopened.retryableQuestion == "When?")
        #expect(reopened.retryableQuestionWasInterrupted)
        let steps = try #require(reopened.turns.last?.steps)
        let tool = try #require(steps.first { $0.kind == .tool })
        #expect(tool.toolName == "list_sources")
        #expect(tool.callID == "call-1")
        #expect(tool.status == .finished)
        // The second turn was cut off: no step is left running and no stop is invented.
        #expect(!steps.contains { $0.status == .running })
        #expect(!steps.contains { $0.kind == .stop })
        // Restoration only reads: the saved conversation is unchanged.
        #expect(session.canonicalRevision == revision)
        #expect(try session.harnessSnapshot().turns.last?.steps == nil)

        crashed.cancel()
        await crashed.waitUntilSettled()
    }

    @Test func aRetryableQuestionWithItsOwnStepsKeepsThem() async throws {
        // A stopped run already left its steps on the question; a recorded interruption of an
        // earlier attempt must not replace them.
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")], pauseAt: 0)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        let session = try #require(vm.pastSessions().first)
        let questionID = try #require(session.turns.first?.id)
        var turns = try session.harnessSnapshot().turns
        var own = AgentRunStep(kind: .stop, status: .finished)
        own.stopReason = .turnLimit
        turns[turns.count - 1].steps = [own]
        #expect(ChatRunRecovery.sweep(context: context) == 1)

        let recovered = ChatRunRecovery.restoringInterruptedRun(in: turns, session: session, context: context)
        #expect(recovered.interrupted == [questionID])
        #expect(recovered.turns.last?.steps == [own])

        vm.cancel()
        await vm.waitUntilSettled()
    }

    @Test func theLaunchSweepClosesTheBranchADeadProcessLeftOpen() async throws {
        let paused = ChatAgentModel([AgentTurnResponse(text: "Partial")], pauseAt: 0)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let crashed = MeetingChatViewModel(agentModelFactory: { _, _ in paused })
        crashed.configure(meeting: meeting, modelContext: context)
        crashed.send(question: "When?", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where await paused.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let session = try #require(crashed.pastSessions().first)
        let store = SwiftDataAgentSessionStore(context: context)
        let runID = try #require(try store.records(session).compactMap(ChatRunRecord.init).first?.runID)
        let leaf = session.canonicalLeafID

        #expect(ChatRunRecovery.sweep(context: context) == 1)
        let run = try store.snapshot(session).entries.filter { $0.runID == runID }.sorted { $0.ordinal < $1.ordinal }
        guard case .custom(ChatRunBranch.endType, .object(let end))? = run.last?.payload else {
            Issue.record("Expected the branch to end with a run-end entry")
            return
        }
        #expect(end["end"] == .string("interrupted"))
        #expect(end["stopReason"] == .null)
        #expect(run.last?.parentID == run.dropLast().last?.id)
        // The presentation path is untouched, and a second sweep finds nothing left to close.
        #expect(session.canonicalLeafID == leaf)
        #expect(try SwiftDataAgentSessionStore.projection(session).turns.map(\.text) == ["When?"])
        let count = try store.snapshot(session).entries.count
        #expect(ChatRunRecovery.sweep(context: context) == 0)
        #expect(try store.snapshot(session).entries.count == count)
        #expect(try ChatRunBranch.closeIfOpen(runID: runID, end: "interrupted", in: session, store: store) == false)
        #expect(try ChatRunBranch.closeIfOpen(runID: "no-such-run", end: "interrupted", in: session, store: store) == false)

        crashed.cancel()
        await crashed.waitUntilSettled()
    }

    @Test func aSettledRunWhoseEndWasNotSavedIsClosedAsAPersistenceFailure() async throws {
        let paused = ChatAgentModel([AgentTurnResponse(text: "Partial")], pauseAt: 0)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in paused })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where await paused.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let session = try #require(vm.pastSessions().first)
        let store = SwiftDataAgentSessionStore(context: context)
        // The run settled (its record says so) but its end entry never reached the store.
        var record = try #require(try store.records(session).compactMap(ChatRunRecord.init).first)
        record.state = .ended
        try store.put(record.record(), in: session, expectedRevision: session.canonicalRevision)

        #expect(ChatRunRecovery.sweep(context: context) == 0)
        let run = try store.snapshot(session).entries.filter { $0.runID == record.runID }
        guard case .custom(ChatRunBranch.endType, .object(let end))? = run.max(by: { $0.ordinal < $1.ordinal })?.payload else {
            Issue.record("Expected the branch to end with a run-end entry")
            return
        }
        #expect(end["end"] == .string("persistenceFailed"))

        vm.cancel()
        await vm.waitUntilSettled()
    }
}

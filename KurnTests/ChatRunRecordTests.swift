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
}

//
//  ChatReplayHistoryTests.swift
//  KurnTests
//
//  NH06 canonical replay: an earlier answered question goes back to the model as the run that
//  answered it recorded it — tool calls and results included — while the source boundary keeps
//  reads the current run may not make out of its context.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatReplayHistoryTests {
    private static func isToolResult(_ message: AgentMessage) -> Bool {
        if case .tool = message { return true }
        return false
    }

    private static func toolCalls(in messages: [AgentMessage]) -> [String] {
        messages.flatMap { message -> [String] in
            guard case .content(let value) = message else { return [] }
            return value.toolCalls.map(\.name)
        }
    }

    @Test func aSecondQuestionReplaysTheFirstRunsCallsAndResults() async throws {
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources")]),
            AgentTurnResponse(text: "Monday."),
            AgentTurnResponse(text: "In the morning.")
        ])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        vm.send(question: "What time?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()

        let requests = await model.requests
        #expect(requests.count == 3)
        let replayed = try #require(requests.last).messages
        // The first question, its call, the call's result and its answer, then the new question.
        #expect(replayed.count == 5)
        #expect(Self.toolCalls(in: replayed) == ["list_sources"])
        #expect(replayed.filter(Self.isToolResult).count == 1)
        guard case .content(let first)? = replayed.first, case .content(let answer)? = replayed.dropLast().last,
              case .content(let question)? = replayed.last else {
            Issue.record("Expected native messages")
            return
        }
        #expect(first.role == .user && first.text == "When?")
        #expect(answer.role == .assistant && answer.text == "Monday.")
        #expect(question.role == .user && question.text == "What time?")
        // The run recorded which question it answered.
        let session = try #require(vm.pastSessions().first)
        let runs = AgentRunBranch.all(in: try SwiftDataAgentSessionStore(context: context).snapshot(session).entries)
        #expect(runs.compactMap(ChatRunBranch.questionID(of:)) == vm.turns.filter { $0.role == .user }.map(\.id))
    }

    @Test func runsOutsideTheCurrentSourcesReplayAsPlainText() async throws {
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources")]),
            AgentTurnResponse(text: "Monday.")
        ])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        let history = ChatReplayHistory.load(turns: vm.turns.map { .init(id: $0.id, role: $0.role, text: $0.text) },
                                             session: session, store: SwiftDataAgentSessionStore(context: context))
        let run = try #require(history.runs.first)
        let recorded = try #require(ChatRunBranch.authorization(of: run))

        // Under the same authorization the run stands in for the question and its answer.
        #expect(history.messages(for: recorded).filter(Self.isToolResult).count == 1)
        // A meeting the current run may not read, or other sources, keeps its reads out.
        let narrowed = ChatRunAuthorization(scope: recorded.scope, meetingIDs: [], model: recorded.model)
        let otherScope = ChatRunAuthorization(scope: ChatSourceScope(kind: .library), meetingIDs: Set(recorded.meetingIDs),
                                              model: recorded.model)
        for authorization in [narrowed, otherScope] {
            let plain = history.messages(for: authorization)
            #expect(plain.count == 2)
            #expect(!plain.contains(where: Self.isToolResult))
            #expect(Self.toolCalls(in: plain).isEmpty)
        }
    }

    @Test func aSavedCompactionIsReusedOnlyWhereItsRunMayBeRead() async throws {
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources")]),
            AgentTurnResponse(text: "Monday.")
        ])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        let store = SwiftDataAgentSessionStore(context: context)
        // The run compacted before its answer, keeping only the answer.
        let snapshot = try store.snapshot(session)
        let run = try #require(AgentRunBranch.all(in: snapshot.entries).first)
        let answerID = try #require(run.answer?.id)
        let checkpoint = AgentCompactionCheckpoint(summary: "Asked when; listed the sources.", firstKeptMessageID: answerID,
                                                   tokensBefore: 900, tokensAfter: 100, splitTurn: false)
        let entry = try AgentSessionEntry(sessionID: snapshot.sessionID, id: UUID().uuidString,
            parentID: run.entries.last?.id, ordinal: snapshot.entries.count + 1, createdAt: AgentSessionEntry.time(),
            payload: .custom(type: AgentCompactionCheckpoint.entryType,
                             data: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(checkpoint))),
            metadata: .object(["runID": .string(run.runID)]))
        try store.commitNow(AgentSessionCommit(sessionID: snapshot.sessionID, expectedRevision: snapshot.revision,
                                               entries: [entry], leafID: snapshot.leafID))

        let history = ChatReplayHistory.load(turns: vm.turns.map { .init(id: $0.id, role: $0.role, text: $0.text) },
                                             session: session, store: store)
        let recorded = try #require(ChatRunBranch.authorization(of: try #require(history.runs.first)))
        let reused = history.messages(for: recorded)
        #expect(reused.first == .user(AgentContextCompactor.summaryPrefix + checkpoint.summary))
        #expect(reused.dropFirst().map(\.canonicalID) == [answerID])
        // A run the current one may not read lends it neither its reads nor its summary.
        let narrowed = ChatRunAuthorization(scope: recorded.scope, meetingIDs: [], model: recorded.model)
        #expect(!history.messages(for: narrowed).contains(reused[0]))
    }

    @Test func aQuestionWithoutACompletedRunReplaysAsPlainText() throws {
        let question = ChatReplayHistory.ShownTurn(id: UUID(), role: .user, text: "When?")
        let answer = ChatReplayHistory.ShownTurn(id: UUID(), role: .assistant, text: "Monday.")
        let history = ChatReplayHistory(turns: [question, answer])
        let authorization = ChatRunAuthorization(scope: ChatSourceScope(kind: .library), meetingIDs: [], model: "openAI:gpt-4o")

        let messages = history.messages(for: authorization)
        guard case .user("When?")? = messages.first, case .assistant("Monday.", let calls, _)? = messages.last else {
            Issue.record("Expected the plain question and answer")
            return
        }
        #expect(messages.count == 2)
        #expect(calls.isEmpty)
    }
}

//
//  ChatRunTranscriptTests.swift
//  KurnTests
//
//  NH05 canonical run history: a chat run commits its native messages to its own branch of the
//  saved session before dependent work, anchored at the accepted question, without moving the
//  presentation leaf; a failed commit fails the run before any model request.
//

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatRunTranscriptTests {
    private struct SaveFailure: Error {}

    private static func runEntries(_ session: ChatSession, context: ModelContext) throws -> [AgentSessionEntry] {
        try SwiftDataAgentSessionStore(context: context).snapshot(session).entries.filter {
            ChatRunTranscriptWriter.runID(of: $0) != nil
        }
    }

    private static func activePath(_ session: ChatSession, context: ModelContext) throws -> [AgentSessionEntry] {
        let snapshot = try SwiftDataAgentSessionStore(context: context).snapshot(session)
        return try AgentEntryGraph(sessionID: snapshot.sessionID, entries: snapshot.entries, leafID: snapshot.leafID).activePath
    }

    @Test func aRunRecordsItsMessagesOnABranchAnchoredAtTheQuestion() async throws {
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

        let run = try Self.runEntries(session, context: context)
        let messages = run.compactMap { entry -> AgentMessage? in
            if case .message(let message) = entry.payload { return message }; return nil
        }
        #expect(messages.count == 4)
        guard case .content(let question)? = messages.first, case .content(let answer)? = messages.last,
              case .tool? = messages.dropFirst(2).first else {
            Issue.record("Expected question, tool call, tool result and answer")
            return
        }
        #expect(question.role == .user && question.text == "When?")
        #expect(answer.role == .assistant && answer.text == "Monday.")
        // One chain, each entry the child of the previous, tagged with the run record's ID.
        let record = try #require(try SwiftDataAgentSessionStore(context: context).records(session).compactMap(ChatRunRecord.init).first)
        #expect(Set(run.compactMap(ChatRunTranscriptWriter.runID(of:))) == [record.runID])
        for (parent, child) in zip(run, run.dropFirst()) { #expect(child.parentID == parent.id) }
        // The anchor is on the presentation path, and the presentation path holds no run entry.
        let path = try Self.activePath(session, context: context)
        #expect(path.contains { $0.id == run.first?.parentID })
        #expect(!path.contains { ChatRunTranscriptWriter.runID(of: $0) != nil })
        #expect(try SwiftDataAgentSessionStore.projection(session).turns.map(\.text) == ["When?", "Monday."])
        // The branch opens with the run's authorization and closes with how it ended.
        guard case .custom(ChatRunTranscriptWriter.startType, .object(let start))? = run.first?.payload,
              case .object(let authorization)? = start["authorization"],
              case .custom(ChatRunTranscriptWriter.endType, .object(let end))? = run.last?.payload else {
            Issue.record("Expected run start and end entries")
            return
        }
        #expect(authorization["meetingIDs"] == .array([.string(meeting.id.uuidString)]))
        #expect(authorization["model"] == .string("openAI:gpt-4o"))
        #expect(end["end"] == .string("completed"))
        #expect(end["stopReason"] == .string("completed"))
    }

    @Test func aCancelledRunRecordsHowItEnded() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")], pauseAt: 0)
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where await model.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        vm.cancel()
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)

        let run = try Self.runEntries(session, context: context)
        #expect(run.first?.kind == ChatRunTranscriptWriter.startType)
        guard case .custom(ChatRunTranscriptWriter.endType, .object(let end))? = run.last?.payload else {
            Issue.record("Expected a run end entry")
            return
        }
        #expect(end["end"] == .string("cancelled"))
        #expect(end["stopReason"] == .null)
        #expect(vm.retryableQuestion == "When?")
    }

    @Test func eachRunHasItsOwnBranchAndTheConversationReopensUnchanged() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday."), AgentTurnResponse(text: "Tuesday.")])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        vm.send(question: "And then?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)

        let runs = Dictionary(grouping: try Self.runEntries(session, context: context)) { ChatRunTranscriptWriter.runID(of: $0) ?? "" }
        #expect(runs.count == 2)
        let path = Set(try Self.activePath(session, context: context).map(\.id))
        for entries in runs.values {
            #expect(path.contains(entries.first?.parentID ?? ""))
        }
        let reopened = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        reopened.configure(meeting: meeting, modelContext: context)
        reopened.load(session: session)
        #expect(reopened.turns.map(\.text) == ["When?", "Monday.", "And then?", "Tuesday."])
    }

    @Test func aFailedCommitFailsTheRunBeforeAnyRequest() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        // The question is saved; the store can no longer validate the session for the run's writes.
        let session = try #require(vm.pastSessions().first)
        session.canonicalRevision = 0
        await vm.waitUntilSettled()

        let requests = await model.requests
        #expect(requests.isEmpty)
        #expect(vm.retryableQuestion == "When?")
        #expect(vm.error != nil)
    }

    @Test func theWriterNeverMovesTheLeafAndRollsBackAFailedSave() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        let leaf = session.canonicalLeafID
        let ordinal = session.canonicalOrdinal

        let writer = ChatRunTranscriptWriter(runID: "run-a", session: session, store: SwiftDataAgentSessionStore(context: context))
        try writer.append(AgentUsage(inputTokens: 10, outputTokens: 2))
        try writer.append(AgentUsage(inputTokens: 12, outputTokens: 3))
        #expect(session.canonicalLeafID == leaf)
        #expect(session.canonicalOrdinal == ordinal + 2)
        let usage = try Self.runEntries(session, context: context).filter { ChatRunTranscriptWriter.runID(of: $0) == "run-a" }
        #expect(usage.map(\.kind) == [ChatRunTranscriptWriter.usageType, ChatRunTranscriptWriter.usageType])
        #expect(usage.first?.parentID == leaf)
        #expect(usage.last?.parentID == usage.first?.id)

        let failing = ChatRunTranscriptWriter(runID: "run-b", session: session,
            store: SwiftDataAgentSessionStore(context: context, save: { _ in throw SaveFailure() }))
        #expect(throws: SaveFailure.self) { try failing.append(AgentUsage(inputTokens: 1, outputTokens: 1)) }
        #expect(failing.lastEntryID == nil)
        #expect(session.canonicalOrdinal == ordinal + 2)
        #expect(session.canonicalLeafID == leaf)
        #expect(try SwiftDataAgentSessionStore.projection(session).turns.map(\.text) == ["When?", "Monday."])
    }

    @Test func aDeletedSessionIsNotWritten() async throws {
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let session = try #require(vm.pastSessions().first)
        let writer = ChatRunTranscriptWriter(runID: "run-a", session: session, store: SwiftDataAgentSessionStore(context: context))
        context.delete(session)
        try context.save()
        #expect(throws: CancellationError.self) { try writer.append(AgentUsage(inputTokens: 1, outputTokens: 1)) }
    }
}

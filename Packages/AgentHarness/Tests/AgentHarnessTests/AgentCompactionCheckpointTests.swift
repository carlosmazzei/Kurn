import Foundation
import Testing
@testable import AgentHarness

/// NH06 persistent compaction: a summary compaction is committed before the request that uses it,
/// and a later run replaying the same history reuses it.
@Suite struct AgentCompactionCheckpointTests {
    private struct Failure: Error {}

    private func message(_ id: String, _ role: AgentContentMessage.Role, _ text: String) throws -> AgentMessage {
        .content(try AgentContentMessage(id: id, timestampMilliseconds: nil, role: role,
                                         blocks: [AgentContentBlock(id: "text", content: .text(text))]))
    }

    private var policy: AgentContextPolicy { AgentContextPolicy(contextWindow: 1_000, reserveTokens: 0, keepRecentTokens: 100) }

    private func history() throws -> [AgentMessage] {
        [try message("h1", .user, tokens(700)), try message("h2", .assistant, tokens(300))]
    }

    /// Runs one question over `history` through a branch-mode owner and returns the log.
    private func record(_ responses: [AgentTurnResponse]) async throws -> [AgentSessionEntry] {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let run = try await session.start(harness: NativeHarness(model: ScriptedAgentModel(responses), contextPolicy: policy),
                                          systemPrompt: "", history: try history(), prompt: "Question", tools: [])
        do { for try await _ in run.events {} } catch {}
        _ = await session.waitUntilSettled()
        return await store.entries
    }

    @Test func aSummaryIsCommittedBeforeTheRequestThatUsesIt() async throws {
        let entries = try await record([AgentTurnResponse(text: "Turn summary"), AgentTurnResponse(text: "Answer")])
        let run = try #require(AgentRunBranch.all(in: entries).first)
        let checkpoint = try #require(run.checkpoints.first)

        #expect(run.checkpoints.count == 1)
        #expect(checkpoint.firstKeptMessageID == "h2")
        #expect(checkpoint.splitTurn)
        #expect(checkpoint.summary.hasSuffix("Turn summary"))
        #expect(checkpoint.tokensAfter < checkpoint.tokensBefore)
        // Saved before the answer the compacted request produced.
        let saved = try #require(entries.firstIndex { $0.kind == AgentCompactionCheckpoint.entryType })
        let answer = try #require(entries.firstIndex {
            if case .message(.content(let value)) = $0.payload { return value.role == .assistant }
            return false
        })
        #expect(saved < answer)
        // Replaying the same history reuses the summary instead of the messages it covered.
        let replayed = AgentCompactionCheckpoint.compacting(try history() + run.contextMessages, with: run.checkpoints)
        #expect(replayed.first == .user(AgentContextCompactor.summaryPrefix + checkpoint.summary))
        #expect(replayed.dropFirst().first?.canonicalID == "h2")
        #expect(replayed.count == 1 + 1 + run.contextMessages.count)
    }

    @Test func anOverflowRetryRunsOnlyAfterItsSummaryIsSaved() async throws {
        let store = SessionTestStore()
        try await store.appendHostEntry("question")
        let session = try AgentSession(sessionID: "session", store: store, appendMode: .branch)
        let model = ResultScriptedAgentModel([.failure(ResultScriptedAgentModel.Overflow()),
                                             .success(AgentTurnResponse(text: "Turn summary")),
                                             .success(AgentTurnResponse(text: "Answer"))])
        // A large window: only the provider's rejection makes this run compact.
        let harness = NativeHarness(model: model, contextPolicy: AgentContextPolicy(contextWindow: 100_000, reserveTokens: 0,
                                                                                    keepRecentTokens: 100),
                                    isContextOverflow: { $0 is ResultScriptedAgentModel.Overflow })
        let run = try await session.start(harness: harness, systemPrompt: "", history: try history(), prompt: "Question", tools: [])
        do { for try await _ in run.events {} } catch {}
        #expect(await session.waitUntilSettled().end == .completed)
        let entries = await store.entries
        let branch = try #require(AgentRunBranch.all(in: entries).first)

        #expect(await model.requests.count == 3)
        #expect(branch.checkpoints.map(\.firstKeptMessageID) == ["h2"])
        #expect(branch.answer?.text == "Answer")
        let saved = try #require(entries.firstIndex { $0.kind == AgentCompactionCheckpoint.entryType })
        let answer = try #require(entries.firstIndex {
            if case .message(.content(let value)) = $0.payload { return value.role == .assistant && value.text == "Answer" }
            return false
        })
        #expect(saved < answer)
        // The retried request was the compacted one.
        let retried = try #require(await model.requests.last)
        #expect(retried.messages.first == .user(AgentContextCompactor.summaryPrefix + branch.checkpoints[0].summary))
    }

    @Test func anUnusableSummaryWritesNoCheckpoint() async throws {
        let entries = try await record([AgentTurnResponse(text: "Cut off", stopReason: .maxTokens),
                                        AgentTurnResponse(text: "Answer")])
        let run = try #require(AgentRunBranch.all(in: entries).first)

        #expect(run.checkpoints.isEmpty)
        #expect(!entries.contains { $0.kind == AgentCompactionCheckpoint.entryType })
        #expect(run.answer?.text == "Answer")
    }

    @Test func aCheckpointThatCannotBeSavedStopsTheRunBeforeItsRequest() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Turn summary"), AgentTurnResponse(text: "Answer")])
        let harness = NativeHarness(model: model, contextPolicy: policy).persistingCompaction { _ in throw Failure() }
        await #expect(throws: Failure.self) { try await agentEvents(harness, history: try history()) }
        // Only the summary request was sent; nothing ran on the unsaved context.
        #expect(await model.requests.count == 1)
    }

    @Test func legacyHistoryWithoutIdentitiesIsNotCheckpointed() async throws {
        let model = ScriptedAgentModel([AgentTurnResponse(text: "Turn summary"), AgentTurnResponse(text: "Answer")])
        let saved = SavedCheckpoints()
        let harness = NativeHarness(model: model, contextPolicy: policy).persistingCompaction { await saved.add($0) }
        _ = try await agentEvents(harness, history: [.user(tokens(700)), .assistant(text: tokens(300), toolCalls: [])])
        // The context was still compacted; only a kept message with an identity can anchor a checkpoint.
        #expect(await model.requests.count == 2)
        #expect(await saved.values.isEmpty)
    }

    @Test func theNewestApplicableCheckpointWins() throws {
        let messages = [try message("a", .user, "A"), try message("b", .assistant, "B"), try message("c", .user, "C")]
        let older = AgentCompactionCheckpoint(summary: "old", firstKeptMessageID: "b", tokensBefore: 10, tokensAfter: 5, splitTurn: false)
        let newer = AgentCompactionCheckpoint(summary: "new", firstKeptMessageID: "c", tokensBefore: 10, tokensAfter: 5, splitTurn: false)
        let elsewhere = AgentCompactionCheckpoint(summary: "x", firstKeptMessageID: "z", tokensBefore: 10, tokensAfter: 5, splitTurn: false)

        #expect(AgentCompactionCheckpoint.compacting(messages, with: [older, newer, elsewhere])
            == [.user(AgentContextCompactor.summaryPrefix + "new"), messages[2]])
        #expect(AgentCompactionCheckpoint.compacting(messages, with: [older])
            == [.user(AgentContextCompactor.summaryPrefix + "old")] + messages.suffix(2))
        #expect(AgentCompactionCheckpoint.compacting(messages, with: [elsewhere]) == messages)
        #expect(elsewhere.applied(to: messages) == nil)
    }
}

private actor SavedCheckpoints {
    var values: [AgentCompactionCheckpoint] = []
    func add(_ value: AgentCompactionCheckpoint) { values.append(value) }
}

import Foundation
import Testing
@testable import AgentHarness

/// The session tree (NH09): alternatives at a message, navigation that only moves the leaf, fork
/// and clone copies that keep the source's tree, labels as detached metadata and usage over
/// every branch versus the selected path.
@Suite struct AgentSessionTreeTests {
    /// Builds a log one entry at a time; each entry's parent is given by ID.
    private struct Log {
        var entries: [AgentSessionEntry] = []

        mutating func message(_ id: String, _ role: AgentContentMessage.Role, after parent: String?,
                              run: String? = nil) throws {
            let message = try AgentContentMessage(id: id, timestampMilliseconds: 1, role: role,
                blocks: [AgentContentBlock(id: "text", content: .text(id))])
            try append(id, parent, .message(.content(message)), run: run)
        }

        mutating func custom(_ id: String, _ type: String, after parent: String?, run: String? = nil,
                             data: JSONValue = .object([:])) throws {
            try append(id, parent, .custom(type: type, data: data), run: run)
        }

        mutating func append(_ id: String, _ parent: String?, _ payload: AgentSessionEntry.Payload, run: String?) throws {
            entries.append(try AgentSessionEntry(sessionID: "session", id: id, parentID: parent, ordinal: entries.count + 1,
                createdAt: AgentSessionEntry.time(), payload: payload,
                metadata: run.map { .object(["runID": .string($0)]) }))
        }

        func tree(leaf: String?) throws -> AgentSessionTree {
            try AgentSessionTree(AgentSessionSnapshot(sessionID: "session", revision: 3, leafID: leaf, entries: entries))
        }
    }

    /// q1 → a1 → state1, then q2 → a2 → state2 under state1, a run answering q2, and an
    /// alternative q2b → a2b → state3 under a1 (a question asked again after dropping q2).
    private func branched() throws -> Log {
        var log = Log()
        try log.message("q1", .user, after: nil)
        try log.message("a1", .assistant, after: "q1")
        try log.custom("state1", "kurn.presentation-state.v1", after: "a1")
        try log.message("q2", .user, after: "state1")
        try log.custom("run2-start", AgentRunBranch.startType, after: "q2", run: "run2")
        try log.message("run2-reply", .assistant, after: "run2-start", run: "run2")
        try log.custom("run2-usage", "agent.usage.v1", after: "run2-reply", run: "run2",
                       data: .object(["inputTokens": .number(100), "outputTokens": .number(10)]))
        try log.message("a2", .assistant, after: "q2")
        try log.custom("state2", "kurn.presentation-state.v1", after: "a2")
        try log.message("q2b", .user, after: "a1")
        try log.custom("run3-start", AgentRunBranch.startType, after: "q2b", run: "run3")
        try log.custom("run3-usage", "agent.usage.v1", after: "run3-start", run: "run3",
                       data: .object(["inputTokens": .number(40), "outputTokens": .number(4)]))
        try log.message("a2b", .assistant, after: "q2b")
        try log.custom("state3", "kurn.presentation-state.v1", after: "a2b")
        return log
    }

    @Test func alternativesAreTheMessagesThatStandInTheSamePlace() throws {
        let tree = try branched().tree(leaf: "state3")

        #expect(tree.alternatives(of: "q2b") == ["q2", "q2b"])
        #expect(tree.alternatives(of: "q2") == ["q2", "q2b"])
        #expect(tree.alternatives(of: "q1") == ["q1"])
        // A run's own messages are never alternatives of the conversation's.
        #expect(tree.alternatives(of: "a2") == ["a2"])
        #expect(tree.alternatives(of: "run2-reply").isEmpty)
    }

    @Test func navigationOpensABranchWhereItWasLeftAndChangesOnlyTheLeaf() throws {
        let tree = try branched().tree(leaf: "state3")

        #expect(tree.latestLeaf(under: "q2") == "state2")
        #expect(tree.latestLeaf(under: "q2b") == "state3")
        #expect(tree.latestLeaf(under: "state2") == "state2")
        let commit = try tree.navigation(to: "state2", expectedRevision: 3)
        #expect(commit.entries.isEmpty && commit.leafID == "state2" && commit.expectedRevision == 3)
        // The leaf can never be a run's entry.
        #expect(throws: AgentSessionStoreError.self) { try tree.navigation(to: "run2-reply", expectedRevision: 3) }
        #expect(throws: AgentSessionStoreError.self) { try tree.navigation(to: "missing", expectedRevision: 3) }
    }

    @Test func aForkCopiesThePathBeforeItsQuestionWithoutLaterRunsOrBranches() throws {
        let tree = try branched().tree(leaf: "state2")
        let fork = try tree.copy(through: "state1", into: "fork")

        #expect(fork.map(\.id) == ["q1", "a1", "state1"])
        #expect(fork.allSatisfy { $0.sessionID == "fork" })
        #expect(fork.map(\.ordinal) == [1, 2, 3])
        _ = try AgentEntryGraph(sessionID: "fork", entries: fork, leafID: "state1")
    }

    @Test func aCloneCopiesTheSelectedPathWithTheRunsThatAnsweredIt() throws {
        var log = try branched()
        let tree = try log.tree(leaf: "state2")
        try log.append("label", nil, .custom(type: AgentSessionTree.Label.entryType,
            data: .object(["targetID": .string("q2"), "label": .string("Plan")])), run: nil)
        try log.append("label-b", nil, .custom(type: AgentSessionTree.Label.entryType,
            data: .object(["targetID": .string("q2b"), "label": .string("Other")])), run: nil)
        let labelled = try log.tree(leaf: "state2")
        let clone = try labelled.copy(through: tree.leafID, into: "clone")

        #expect(clone.map(\.id) == ["q1", "a1", "state1", "q2", "run2-start", "run2-reply", "run2-usage", "a2", "state2", "label"])
        let copied = try AgentSessionTree(AgentSessionSnapshot(sessionID: "clone", revision: 1, leafID: "state2", entries: clone))
        #expect(copied.activePath.map(\.id) == tree.activePath.map(\.id))
        #expect(copied.labels == ["q2": "Plan"])
        #expect(AgentRunBranch.all(in: clone).map(\.runID) == ["run2"])
        // The source keeps its whole tree.
        #expect(labelled.entries.count == log.entries.count)
    }

    @Test func labelsAreDetachedMetadataAndTheNewestWins() throws {
        var log = try branched()
        let tree = try log.tree(leaf: "state3")
        let label = try tree.labelEntry("  Decision  ", on: "q1", id: "label-1")
        #expect(label.parentID == nil && label.ordinal == log.entries.count + 1)
        log.entries.append(label)
        log.entries.append(try log.tree(leaf: "state3").labelEntry(nil, on: "q1", id: "label-2"))
        log.entries.append(try log.tree(leaf: "state3").labelEntry("Kept", on: "a1", id: "label-3"))
        let labelled = try log.tree(leaf: "state3")

        #expect(labelled.labels == ["a1": "Kept"])
        // A label never moves the selected path.
        #expect(labelled.activePath.map(\.id) == tree.activePath.map(\.id))
        #expect(throws: AgentSessionStoreError.self) { try tree.labelEntry("x", on: "missing") }
    }

    @Test func sessionUsageCoversEveryBranchAndContextUsageOnlyTheSelectedPath() throws {
        let tree = try branched().tree(leaf: "state2")
        let other = try branched().tree(leaf: "state3")

        #expect(tree.usage(.session) == AgentUsage(inputTokens: 140, outputTokens: 14))
        #expect(tree.usage(.activePath) == AgentUsage(inputTokens: 100, outputTokens: 10))
        #expect(other.usage(.activePath) == AgentUsage(inputTokens: 40, outputTokens: 4))
        var empty = Log()
        try empty.message("q", .user, after: nil)
        #expect(try empty.tree(leaf: "q").usage(.session) == nil)
    }

    @Test func aCopyRecordsEachCopiedRunsPromptAndToolsAgainstTheRunCopiedBeforeIt() throws {
        let base = try AgentSystemPrompt(sections: [.init(name: "instructions", text: "Be brief."),
                                                    .init(name: "documents", text: "None")])
        let other = try AgentSystemPrompt(sections: [.init(name: "instructions", text: "Be brief."),
                                                     .init(name: "documents", text: "Minutes v1")])
        func json<Value: Encodable>(_ value: Value) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }
        var log = Log()
        try log.message("q1", .user, after: nil)
        // The first run in the log records its prompt in full; the run on the other branch records
        // only a patch on it, and a tool delta from it.
        try log.custom("run1-start", AgentRunBranch.startType, after: "q1", run: "run1", data: .object([
            "system": try json(base), "tools": try json(AgentToolLoadout(names: ["list_sources"], previous: nil))]))
        try log.message("a1", .assistant, after: "q1")
        try log.message("q1b", .user, after: nil)
        try log.custom("run2-start", AgentRunBranch.startType, after: "q1b", run: "run2", data: .object([
            "systemPatch": try json(base.patch(to: other)),
            "tools": try json(AgentToolLoadout(names: ["list_sources", "read_document"], previous: ["list_sources"]))]))
        try log.message("a1b", .assistant, after: "q1b")

        let clone = try log.tree(leaf: "a1b").copy(through: "a1b", into: "clone")
        let runs = AgentRunBranch.all(in: clone)
        #expect(runs.map(\.runID) == ["run2"])
        #expect(runs.first?.startFields["systemPatch"] == nil)
        #expect(AgentRunBranch.systemPrompts(of: runs) == [other])
        #expect(runs.first?.toolLoadout == AgentToolLoadout(names: ["list_sources", "read_document"], previous: nil))
    }
}

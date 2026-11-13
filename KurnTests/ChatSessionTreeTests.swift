import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// A saved conversation as a tree (NH09): navigation that changes only the selected branch, fork
/// and clone into new conversations that leave the source as it was, labels and renames as
/// metadata, and documents that follow the branch shown.
@MainActor
struct ChatSessionTreeTests {
    private struct Seeded {
        let session: ChatSession
        let q1: PersistedChatTurn, a1: PersistedChatTurn
        let q2: PersistedChatTurn, a2: PersistedChatTurn
        let q2b: PersistedChatTurn, a2b: PersistedChatTurn
        let first: ChatDocumentArtifact, second: ChatDocumentArtifact, other: ChatDocumentArtifact
    }

    private func turn(_ role: ChatMessage.Role, _ text: String) -> PersistedChatTurn {
        PersistedChatTurn(id: UUID(), role: role, text: text, usage: nil, costUSD: nil, elapsedSeconds: nil)
    }

    /// q1/a1 with a document; q2/a2 revising it; then q2 dropped and q2b/a2b asked in its place,
    /// revising the same document to the same version with other content.
    private func seed(_ context: ModelContext) throws -> Seeded {
        let session = ChatSession(meeting: nil, title: "Planning")
        context.insert(session)
        let store = SwiftDataAgentSessionStore(context: context)
        let (q1, a1) = (turn(.user, "First question"), turn(.assistant, "First answer"))
        let (q2, a2) = (turn(.user, "Second question"), turn(.assistant, "Second answer"))
        let (q2b, a2b) = (turn(.user, "Asked again"), turn(.assistant, "Other answer"))
        let first = ChatDocumentArtifact(title: "Minutes", markdown: "One")
        let second = ChatDocumentArtifact(id: first.id, title: "Minutes", markdown: "Two", version: 2)
        let other = ChatDocumentArtifact(id: first.id, title: "Minutes", markdown: "Other", version: 2)
        try store.writePresentation(session, turns: [q1, a1], scope: nil, artifacts: [first])
        try store.writePresentation(session, turns: [q1, a1, q2, a2], scope: nil, artifacts: [second])
        try store.writePresentation(session, turns: [q1, a1, q2b, a2b], scope: nil, artifacts: [other])
        return Seeded(session: session, q1: q1, a1: a1, q2: q2, a2: a2, q2b: q2b, a2b: a2b,
                      first: first, second: second, other: other)
    }

    @Test func navigationSelectsAnotherBranchAndItsDocumentsWithoutLosingAny() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let session = seeded.session
        let store = SwiftDataAgentSessionStore(context: context)
        let entries = try store.snapshot(session).entries.count
        let branches = ChatBranchPresentation(tree: try store.tree(session))
        let versions = try #require(branches.alternatives[seeded.q2b.id])
        #expect(versions.count == 2 && versions.index == 1)

        try store.navigate(session, to: try #require(versions.entryID(offset: -1)), expectedRevision: session.canonicalRevision)
        #expect(try session.harnessSnapshot().turns.map(\.text) == ["First question", "First answer", "Second question", "Second answer"])
        #expect(try session.harnessSnapshot().artifacts == [seeded.second])
        #expect(session.turns.map(\.text) == ["First question", "First answer", "Second question", "Second answer"])
        // Navigation writes no entry: both branches and all three document revisions are kept.
        #expect(try store.snapshot(session).entries.count == entries)
        #expect(session.harnessRevisions.count == 3)

        // A stale revision is a conflict and changes nothing.
        let leaf = session.canonicalLeafID
        #expect(throws: AgentSessionStoreError.conflict) {
            try store.navigate(session, to: versions.entryIDs[1], expectedRevision: session.canonicalRevision - 1)
        }
        #expect(session.canonicalLeafID == leaf)
        try store.navigate(session, to: versions.entryIDs[1], expectedRevision: session.canonicalRevision)
        #expect(try session.harnessSnapshot().artifacts == [seeded.other])
    }

    @Test func aForkStartsBeforeItsQuestionAndACloneKeepsTheBranchShown() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let source = seeded.session
        let store = SwiftDataAgentSessionStore(context: context)
        let tree = try store.tree(source)
        let entries = tree.entries.count
        let branches = ChatBranchPresentation(tree: tree)
        try store.label(source, entry: try #require(branches.entryIDs[seeded.q1.id]), as: "Kickoff")

        let before = try store.tree(source).entry(try #require(branches.entryIDs[seeded.q2b.id]))?.parentID
        let fork = try #require(try store.copy(source, through: before, title: source.title))
        #expect(try fork.harnessSnapshot().turns.map(\.id) == [seeded.q1.id, seeded.a1.id])
        #expect(try fork.harnessSnapshot().artifacts == [seeded.first])
        #expect(ChatBranchPresentation(tree: try store.tree(fork)).labels == [seeded.q1.id: "Kickoff"])
        // Nothing comes before the first question, so a fork from it is a new conversation.
        #expect(try store.copy(source, through: nil, title: source.title) == nil)

        let clone = try #require(try store.copy(source, through: source.canonicalLeafID, title: "Copy"))
        #expect(try clone.harnessSnapshot().turns.map(\.id) == [seeded.q1.id, seeded.a1.id, seeded.q2b.id, seeded.a2b.id])
        #expect(try clone.harnessSnapshot().artifacts == [seeded.other])
        #expect(clone.title == "Copy" && clone.meeting == nil)
        #expect(clone.harnessRevisions.allSatisfy { $0.id.hasPrefix(clone.id.uuidString) })
        try store.migrate(clone)
        // The source keeps every branch.
        #expect(try store.tree(source).entries.count == entries + 1)
        #expect(ChatBranchPresentation(tree: try store.tree(source)).alternatives[seeded.q2b.id]?.count == 2)
    }

    @Test func labelsAndRenamesAreMetadata() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let session = seeded.session
        let store = SwiftDataAgentSessionStore(context: context)
        let entryID = try #require(ChatBranchPresentation(tree: try store.tree(session)).entryIDs[seeded.a1.id])
        let leaf = session.canonicalLeafID
        let shown = session.turnsData

        try store.label(session, entry: entryID, as: "  Decision  ")
        #expect(ChatBranchPresentation(tree: try store.tree(session)).labels == [seeded.a1.id: "Decision"])
        try store.label(session, entry: entryID, as: "")
        #expect(ChatBranchPresentation(tree: try store.tree(session)).labels.isEmpty)
        #expect(session.canonicalLeafID == leaf && session.turnsData == shown)

        try store.rename(session, to: "  Weekly sync  ")
        #expect(session.title == "Weekly sync")
        try store.rename(session, to: "   ")
        #expect(session.title == "Weekly sync")
    }

    @Test func theChatMovesBetweenVersionsForksAndDuplicates() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in nil })
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: seeded.session)
        #expect(vm.canChangeBranch)
        #expect(vm.branches.alternatives[seeded.q2b.id]?.count == 2)

        vm.showVersion(of: seeded.q2b.id, offset: -1)
        #expect(vm.turns.map(\.id) == [seeded.q1.id, seeded.a1.id, seeded.q2.id, seeded.a2.id])
        #expect(vm.artifacts == [seeded.second])
        #expect(vm.branches.alternatives[seeded.q2.id]?.index == 0)

        vm.label(turnID: seeded.q2.id, as: "Plan A")
        #expect(vm.branches.labels[seeded.q2.id] == "Plan A")

        vm.fork(from: seeded.q2.id)
        #expect(vm.currentSessionID != seeded.session.id)
        #expect(vm.turns.map(\.id) == [seeded.q1.id, seeded.a1.id])
        #expect(vm.restoredDraft == "Second question")

        vm.load(session: seeded.session)
        vm.restoredDraft = nil
        vm.duplicateConversation()
        #expect(vm.currentSessionID != seeded.session.id)
        #expect(vm.turns.map(\.id) == [seeded.q1.id, seeded.a1.id, seeded.q2.id, seeded.a2.id])
        #expect(vm.branches.labels[seeded.q2.id] == "Plan A")

        vm.fork(from: seeded.q1.id)
        #expect(vm.currentSessionID == nil || vm.turns.isEmpty)
        #expect(vm.turns.isEmpty && vm.restoredDraft == "First question")
        #expect(vm.error == nil)
    }

    @Test func aForkOpensWithTheSourcesAndDocumentsItsQuestionWasAskedWith() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = ChatSession(meeting: nil, title: "Planning")
        context.insert(session)
        let store = SwiftDataAgentSessionStore(context: context)
        let (q1, a1) = (turn(.user, "First question"), turn(.assistant, "First answer"))
        let (q2, q2b) = (turn(.user, "Second question"), turn(.user, "Asked again"))
        let first = ChatDocumentArtifact(title: "Minutes", markdown: "One")
        let revised = ChatDocumentArtifact(id: first.id, title: "Minutes", markdown: "Two", version: 2)
        let narrowed = ChatSourceScope(kind: .library, parts: [.summary])
        try store.writePresentation(session, turns: [q1, a1], scope: nil, artifacts: [first])
        // Sources and the document change after the answer, then a question is asked, dropped and
        // asked again: the new question is written under the answer, beside the older state.
        try store.writePresentation(session, turns: [q1, a1], scope: narrowed, artifacts: [revised])
        try store.writePresentation(session, turns: [q1, a1, q2], scope: narrowed, artifacts: [revised])
        try store.writePresentation(session, turns: [q1, a1, q2b], scope: narrowed, artifacts: [revised])

        let tree = try store.tree(session)
        let question = try #require(ChatBranchPresentation(tree: tree).entryIDs[q2b.id])
        let fork = try #require(try store.copy(session, through: tree.entry(question)?.parentID, title: session.title, askedAt: question))
        #expect(try fork.harnessSnapshot().turns.map(\.id) == [q1.id, a1.id])
        #expect(try fork.harnessSnapshot().scope == narrowed)
        #expect(try fork.harnessSnapshot().artifacts == [revised])
    }
}

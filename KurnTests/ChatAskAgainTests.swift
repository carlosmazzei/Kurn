import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Asking a saved question again in its place (regenerate, edit) and searching saved conversations.
@MainActor
struct ChatAskAgainTests {
    private func answers(_ texts: [String]) -> ChatAgentModel {
        ChatAgentModel(texts.map { AgentTurnResponse(text: $0) })
    }

    @Test func regeneratingAndEditingAddVersionsBesideTheQuestion() async throws {
        let model = answers(["Monday.", "Tuesday.", "Wednesday."])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let first = try #require(vm.turns.first)

        // Regenerate: the same question again, another answer, in the same conversation.
        let session = vm.currentSessionID
        vm.askAgain(first.id, text: first.text, provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        #expect(vm.currentSessionID == session)
        #expect(vm.turns.map(\.text) == ["When?", "Tuesday."])
        let regenerated = try #require(vm.turns.first)
        #expect(vm.branches.alternatives[regenerated.id]?.count == 2)

        // Edit: the question is put in the composer, and sending it asks the new text in its place.
        vm.beginEditing(regenerated.id)
        #expect(vm.editingQuestionID == regenerated.id && vm.draft == "When?")
        vm.askAgain(regenerated.id, text: "Where?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        #expect(vm.editingQuestionID == nil && vm.error == nil)
        #expect(vm.turns.map(\.text) == ["Where?", "Wednesday."])
        let edited = try #require(vm.turns.first)
        #expect(vm.branches.alternatives[edited.id]?.count == 3 && vm.branches.alternatives[edited.id]?.index == 2)

        // Every earlier version is still there.
        vm.showVersion(of: edited.id, offset: -2)
        #expect(vm.turns.map(\.text) == ["When?", "Monday."])
    }

    @Test func editingCanBeCancelledAndNeedsASavedQuestion() async throws {
        let model = answers(["Monday."])
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.beginEditing(UUID())
        #expect(vm.editingQuestionID == nil)
        vm.send(question: "When?", provider: .openAI, model: "gpt-4o")
        await vm.waitUntilSettled()
        let question = try #require(vm.turns.first)
        vm.beginEditing(question.id)
        // A question that is not taken leaves the edit where it was, to try again.
        #expect(!vm.askAgain(question.id, text: "  ", provider: .openAI, model: "gpt-4o"))
        #expect(vm.editingQuestionID == question.id && vm.draft == "When?" && vm.turns.count == 2)
        vm.cancelEditing()
        #expect(vm.editingQuestionID == nil && vm.draft.isEmpty)
    }

    @Test func aRewindChecksItsRevisionAndItsQuestion() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = ChatSession(meeting: nil, title: "Planning")
        context.insert(session)
        let store = SwiftDataAgentSessionStore(context: context)
        let question = PersistedChatTurn(id: UUID(), role: .user, text: "Q", usage: nil, costUSD: nil, elapsedSeconds: nil)
        let answer = PersistedChatTurn(id: UUID(), role: .assistant, text: "A", usage: nil, costUSD: nil, elapsedSeconds: nil)
        try store.writePresentation(session, turns: [question, answer], scope: nil, artifacts: [])
        let entryID = try #require(ChatBranchPresentation(tree: store.tree(session)).entryIDs[question.id])
        let revision = session.canonicalRevision
        #expect(throws: AgentSessionStoreError.conflict) {
            try store.rewind(session, before: entryID, expectedRevision: revision - 1)
        }
        #expect(throws: AgentSessionStoreError.notFound) {
            try store.rewind(session, before: "missing", expectedRevision: revision)
        }
        #expect(session.canonicalRevision == revision && session.turns.count == 2)
        // Before the first question there is nothing left to show.
        try store.rewind(session, before: entryID, expectedRevision: revision)
        #expect(session.turns.isEmpty && session.canonicalRevision == revision + 1)
    }

    @Test func searchMatchesEveryWordInTheTitleOrTheTurns() {
        #expect(ChatSessionSearch.match(title: "Budget", texts: [], query: "") == ChatSessionSearch.Match(excerpt: nil))
        #expect(ChatSessionSearch.match(title: "Budget review", texts: ["Nothing"], query: "budget") == ChatSessionSearch.Match(excerpt: nil))
        let match = ChatSessionSearch.match(title: "Planning", texts: ["We agreed the orçamento for Q3."], query: "ORCAMENTO q3")
        #expect(match?.excerpt == "We agreed the orçamento for Q3.")
        #expect(ChatSessionSearch.match(title: "Planning", texts: ["budget"], query: "budget hiring") == nil)

        let long = String(repeating: "a", count: 60) + " needle\nline " + String(repeating: "b", count: 60)
        let excerpt = ChatSessionSearch.excerpt(long, around: long.range(of: "needle")!)
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…") && excerpt.contains("needle line") && !excerpt.contains("\n"))
    }

    @Test func searchFiltersSavedConversations() throws {
        let context = ModelContext(TestModelContainer.make())
        let budget = ChatSession(meeting: nil, title: "Budget")
        let hiring = ChatSession(meeting: nil, title: "Hiring")
        context.insert(budget)
        context.insert(hiring)
        hiring.turns = [PersistedChatTurn(id: UUID(), role: .user, text: "Who joins the budget team?", usage: nil, costUSD: nil,
                                          elapsedSeconds: nil)]
        let results = ChatSessionSearch.results([budget, hiring], query: "budget")
        #expect(results.map(\.session.title) == ["Budget", "Hiring"])
        #expect(results[1].match.excerpt == "Who joins the budget team?")
        #expect(ChatSessionSearch.results([budget, hiring], query: "hiring").map(\.session.title) == ["Hiring"])
    }
}

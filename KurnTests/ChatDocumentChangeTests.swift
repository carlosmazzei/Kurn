import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Tool effects in the chat: replacing a document asks first, a no ends the run, and a document's
/// latest change can be undone from its card.
@MainActor
struct ChatDocumentChangeTests {
    private func turn(_ role: ChatMessage.Role, _ text: String) -> PersistedChatTurn {
        PersistedChatTurn(id: UUID(), role: role, text: text, usage: nil, costUSD: nil, elapsedSeconds: nil)
    }

    /// A saved conversation of `meeting` holding one document at version 1.
    private func savedConversation(_ meeting: Meeting, in context: ModelContext) throws -> (ChatSession, ChatDocumentArtifact) {
        let session = ChatSession(meeting: meeting, title: "Minutes")
        context.insert(session)
        let document = ChatDocumentArtifact(title: "Minutes", markdown: "Body")
        try SwiftDataAgentSessionStore(context: context).writePresentation(session,
            turns: [turn(.user, "Minutes"), turn(.assistant, "Done.")], scope: nil, artifacts: [document])
        return (session, document)
    }

    private func replace(_ document: ChatDocumentArtifact, with markdown: String) throws -> AgentToolCall {
        try chatAgentCall("update_document", arguments: .object([
            "document_id": .string(document.id.uuidString), "title": .string("Revised minutes"), "markdown": .string(markdown)
        ]))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    /// A loaded conversation whose model answers with `responses` for its document.
    private func conversation(_ responses: (ChatDocumentArtifact) throws -> [AgentTurnResponse]) throws
        -> (MeetingChatViewModel, ChatAgentModel, ChatDocumentArtifact) {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let (session, document) = try savedConversation(meeting, in: context)
        let model = ChatAgentModel(try responses(document))
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.load(session: session)
        return (vm, model, document)
    }

    @Test func documentToolsAreClassifiedByEffect() {
        let tools = Dictionary(uniqueKeysWithValues: ChatDocumentTools.make(workspace: ChatDocumentWorkspace()).map { ($0.spec.name, $0) })
        #expect(tools["read_document"]?.effect == .read)
        #expect(tools["create_document"]?.effect == .write)
        #expect(tools["append_to_document"]?.effect == .write)
        #expect(tools["update_document"]?.effect == .destructive)
        let confirmed = tools.values.filter { $0.requiresConfirmation }.map { $0.spec.name }
        #expect(confirmed == ["update_document"])
    }

    @Test func aReplacementRunsOnlyAfterAYesAndCanBeUndone() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let (session, document) = try savedConversation(meeting, in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "", toolCalls: [try replace(document, with: "Revised")]),
                                    AgentTurnResponse(text: "Replaced.")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.load(session: session)
        #expect(!vm.canUndo(document))

        vm.send(question: "Rewrite it", provider: .openAI, model: "gpt-4o")
        await waitUntil { vm.changeConfirmation.pending != nil }
        let request = try #require(vm.changeConfirmation.pending)
        #expect(request.document == document && request.newTitle == "Revised minutes" && request.markdown == "Revised")
        #expect(request.documentTitle == "Minutes")
        // Nothing is replaced while the question is open.
        #expect(vm.artifacts == [document])
        vm.changeConfirmation.answer(true, to: request.id)
        await vm.waitUntilSettled()
        #expect(vm.changeConfirmation.pending == nil)
        #expect(vm.turns.last?.text == "Replaced.")
        let replaced = try #require(vm.artifacts.first)
        #expect(replaced.version == 2 && replaced.markdown == "Revised" && replaced.title == "Revised minutes")

        // Undo restores version 1's title and body as version 3; the replacement stays saved.
        #expect(vm.canUndo(replaced))
        let undo = try #require(vm.undoAction(replaced))
        undo()
        let restored = try #require(vm.artifacts.first)
        #expect(restored == ChatDocumentArtifact(id: document.id, title: "Minutes", markdown: "Body", version: 3))
        #expect(vm.error == nil)
        #expect(try session.harnessSnapshot().artifacts == [restored])
        // Undoing the undo brings the replacement back.
        vm.undoLastChange(of: restored)
        #expect(vm.artifacts.first?.markdown == "Revised" && vm.artifacts.first?.version == 4)
    }

    @Test func aNoEndsTheRunWithTheDocumentUnchanged() async throws {
        // The call comes with narration, which is not an answer to the question.
        let (vm, model, document) = try conversation { [
            AgentTurnResponse(text: "Replacing the document.", toolCalls: [try replace($0, with: "Revised")]),
            AgentTurnResponse(text: "Never")] }
        vm.send(question: "Rewrite it", provider: .openAI, model: "gpt-4o")
        await waitUntil { vm.changeConfirmation.pending != nil }
        vm.changeConfirmation.answer(false)
        await vm.waitUntilSettled()
        // The model is not asked to work around the refusal.
        #expect(await model.requests.count == 1)
        #expect(vm.artifacts == [document])
        let stop = vm.turns.flatMap(\.steps).last { $0.kind == .stop }
        #expect(stop?.stopReason == .terminated)
        // The question stays unanswered, to ask again.
        #expect(vm.turns.last?.role == .user)
        #expect(vm.retryableQuestion != nil)
    }

    @Test func stoppingTheRunAnswersNo() async throws {
        let (vm, _, document) = try conversation { [AgentTurnResponse(text: "", toolCalls: [try replace($0, with: "Revised")]),
                                                     AgentTurnResponse(text: "Never")] }
        vm.send(question: "Rewrite it", provider: .openAI, model: "gpt-4o")
        await waitUntil { vm.changeConfirmation.pending != nil }
        vm.cancel()
        await vm.waitUntilSettled()
        #expect(vm.changeConfirmation.pending == nil)
        #expect(vm.artifacts == [document])
    }

    @Test func undoNeedsAnEarlierVersionAndTheCurrentRevision() throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let (session, document) = try savedConversation(meeting, in: context)
        let store = SwiftDataAgentSessionStore(context: context)
        #expect(try store.previousVersion(of: document.id, in: session) == nil)
        #expect(try store.previousVersion(of: UUID(), in: session) == nil)
        #expect(throws: AgentSessionStoreError.notFound) {
            try store.undoLastChange(of: document.id, in: session, expectedRevision: session.canonicalRevision)
        }
        let shown = try session.harnessSnapshot()
        let replaced = try ChatDocumentEdit.update(document.id, title: nil, markdown: "Revised").applying(to: shown.artifacts)
        try store.writePresentation(session, turns: shown.turns, scope: shown.scope, artifacts: replaced.artifacts)
        #expect(try store.previousVersion(of: document.id, in: session) == document)
        #expect(throws: AgentSessionStoreError.conflict) {
            try store.undoLastChange(of: document.id, in: session, expectedRevision: session.canonicalRevision - 1)
        }
        #expect(try session.harnessSnapshot().artifacts == replaced.artifacts)

        // A document with no earlier version says so instead of failing silently.
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in nil })
        vm.configure(meeting: meeting, modelContext: context)
        vm.load(session: session)
        let forged = ChatDocumentArtifact(id: UUID(), title: "Other", markdown: "Text", version: 2)
        vm.undoLastChange(of: forged)
        #expect(vm.error != nil)
    }

    @Test func aRequestNamesTheDocumentItWouldChange() throws {
        let document = ChatDocumentArtifact(title: "Minutes", markdown: "Body", version: 2)
        let known = ChatChangeRequest(try call(["document_id": .string(document.id.uuidString),
                                                "title": .string("Minutes"), "markdown": .string("New")]), documents: [document])
        #expect(known.document == document && known.newTitle == nil && known.documentTitle == "Minutes" && known.markdown == "New")
        let unknown = ChatChangeRequest(try call(["document_id": .string(UUID().uuidString), "title": .string("Report")]),
                                        documents: [document])
        #expect(unknown.document == nil && unknown.documentTitle == "Report" && unknown.markdown.isEmpty)
        let malformed = ChatChangeRequest(AgentToolCall(id: "x", name: "update_document", arguments: .null, rawArguments: "null"),
                                          documents: [document])
        #expect(malformed.id == "x" && malformed.document == nil && malformed.documentTitle.isEmpty)
    }

    private func call(_ values: [String: JSONValue]) throws -> AgentToolCall {
        let arguments = JSONValue.object(values)
        return AgentToolCall(id: UUID().uuidString, name: "update_document", arguments: arguments,
                             rawArguments: try arguments.encodedString())
    }

    @Test func oneChangeWaitsAtATimeAndOnlyItsOwnAnswerCounts() async {
        let gate = ChatChangeConfirmation()
        let request = ChatChangeRequest(id: "a", document: nil, newTitle: "T", markdown: "M")
        let waiting = Task { await gate.request(request) }
        await waitUntil { gate.pending != nil }
        // A second change while one waits is refused rather than queued behind it.
        #expect(await gate.request(ChatChangeRequest(id: "b", document: nil, newTitle: nil, markdown: "")) == false)
        gate.answer(false, to: "b")
        #expect(gate.pending == request)
        gate.answer(true, to: "a")
        #expect(await waiting.value)
        #expect(gate.pending == nil)
        gate.answer(true)

        let cancelled = Task { await gate.request(request) }
        await waitUntil { gate.pending != nil }
        cancelled.cancel()
        #expect(await cancelled.value == false)
        await waitUntil { gate.pending == nil }
    }
}

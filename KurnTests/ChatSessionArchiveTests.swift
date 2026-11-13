import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Archival export and import of saved conversations (NH10): an import is a new conversation with
/// the whole tree and its document revisions; a restore keeps identity only when it is free; an
/// archive that does not hold writes nothing; the reading export is the branch shown.
@MainActor
struct ChatSessionArchiveTests {
    private struct Seeded {
        let session: ChatSession
        let q1: PersistedChatTurn, q2b: PersistedChatTurn
        let first: ChatDocumentArtifact, other: ChatDocumentArtifact
    }

    private func turn(_ role: ChatMessage.Role, _ text: String) -> PersistedChatTurn {
        PersistedChatTurn(id: UUID(), role: role, text: text, usage: nil, costUSD: nil, elapsedSeconds: nil)
    }

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
        return Seeded(session: session, q1: q1, q2b: q2b, first: first, other: other)
    }

    private func sessionCount(_ context: ModelContext) throws -> Int { try context.fetchCount(FetchDescriptor<ChatSession>()) }

    @Test func anImportIsANewConversationWithTheWholeTreeAndItsDocuments() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        let data = try store.archive(seeded.session)
        let entries = try store.snapshot(seeded.session).entries.count

        let imported = try store.importArchive(data, meeting: nil, defaultTitle: "Imported")
        #expect(imported.id != seeded.session.id && imported.title == "Planning")
        #expect(try imported.harnessSnapshot().turns.map(\.id) == seeded.session.harnessSnapshot().turns.map(\.id))
        #expect(try imported.harnessSnapshot().artifacts == [seeded.other])
        #expect(try store.snapshot(imported).entries.count == entries)
        #expect(imported.harnessRevisions.count == 3 && imported.harnessRevisions.allSatisfy { $0.id.hasPrefix(imported.id.uuidString) })
        #expect(ChatBranchPresentation(tree: try store.tree(imported)).alternatives[seeded.q2b.id]?.count == 2)
        // Every branch came along: the other version opens with its own document revision.
        let versions = try #require(ChatBranchPresentation(tree: try store.tree(imported)).alternatives[seeded.q2b.id])
        try store.navigate(imported, to: versions.entryIDs[0], expectedRevision: imported.canonicalRevision)
        #expect(try imported.harnessSnapshot().artifacts.first?.markdown == "Two")
        // The source is unchanged, and its export is the same archive again.
        #expect(try store.archive(seeded.session) == data)
    }

    @Test func aRestoreKeepsTheIdentityOnlyWhenNoConversationHasIt() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        let data = try store.archive(seeded.session)
        let id = seeded.session.id

        #expect(throws: AgentSessionStoreError.conflict) { try store.importArchive(data, meeting: nil, as: .restore, defaultTitle: "") }
        #expect(try sessionCount(context) == 1)
        context.delete(seeded.session)
        try context.save()
        let restored = try store.importArchive(data, meeting: nil, as: .restore, defaultTitle: "")
        #expect(restored.id == id)
        #expect(try restored.harnessSnapshot().turns.first?.id == seeded.q1.id)
    }

    @Test func anArchiveThatDoesNotHoldWritesNothing() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        let archive = try AgentSessionArchive.decode(try store.archive(seeded.session))
        func data(records: [AgentSessionArchive.Record]) throws -> Data {
            try AgentSessionArchive(sessionID: archive.sessionID, leafID: archive.leafID, entries: archive.entries, records: records).jsonl()
        }
        let revisions = archive.records.filter { $0.type == SwiftDataAgentSessionStore.revisionRecord }
        // A revision a branch shows is missing.
        let missing = try data(records: Array(revisions.dropFirst()))
        // A revision's bytes do not match its identity.
        let forged = try HarnessPresentationCodec.encode(ChatDocumentArtifact(title: "Forged", markdown: "Forged"))
        let tampered = try data(records: revisions.map { record in
            guard case .object(var fields) = record.data else { return record }
            fields["payload"] = .string(forged.base64EncodedString())
            return .init(type: record.type, data: .object(fields))
        })

        for bad in [missing, tampered, Data("not an archive".utf8)] {
            #expect(throws: (any Error).self) { try store.importArchive(bad, meeting: nil, defaultTitle: "Imported") }
        }
        #expect(try sessionCount(context) == 1)
        #expect(try context.fetchCount(FetchDescriptor<HarnessArtifactRevision>()) == 3)
    }

    @Test func theReadingExportIsTheBranchShown() throws {
        let markdown = ChatConversationMarkdown.render(title: "Planning", turns: [turn(.user, "When?"), turn(.assistant, "Monday.")],
                                                       artifacts: [ChatDocumentArtifact(title: "Minutes", markdown: "x", version: 3)])
        #expect(markdown.hasPrefix("# Planning\n"))
        #expect(markdown.contains("When?") && markdown.contains("Monday."))
        #expect(markdown.contains("### Minutes (v3)\n\nx"))
    }

    @Test func theChatExportsAndImportsConversations() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in nil })
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: seeded.session)

        let archive = try #require(vm.exportArchive())
        let readable = try #require(vm.exportReadable())
        #expect(try String(contentsOf: readable, encoding: .utf8).contains("Asked again"))
        vm.importConversation(from: archive)
        #expect(vm.error == nil && vm.currentSessionID != seeded.session.id)
        #expect(vm.turns.map(\.text) == ["First question", "First answer", "Asked again", "Other answer"])
        #expect(try sessionCount(context) == 2)

        let bad = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data("{}".utf8).write(to: bad)
        vm.importConversation(from: bad)
        #expect(vm.error != nil)
        #expect(try sessionCount(context) == 2)
        try? FileManager.default.removeItem(at: bad)
    }

    @Test func aBranchThatCannotOpenRejectsTheWholeImport() throws {
        let context = ModelContext(TestModelContainer.make())
        let seeded = try seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        let archive = try AgentSessionArchive.decode(try store.archive(seeded.session))
        // A question on a branch that is not selected loses the metadata its turn is read from.
        let broken = try archive.entries.map { entry -> AgentSessionEntry in
            guard case .message(.content(let message)) = entry.payload, message.id == seeded.q1.id.uuidString else { return entry }
            return try AgentSessionEntry(sessionID: entry.sessionID, id: entry.id, parentID: entry.parentID, ordinal: entry.ordinal,
                                         createdAt: entry.createdAt, payload: entry.payload, metadata: nil)
        }
        let data = try AgentSessionArchive(sessionID: archive.sessionID, leafID: archive.leafID, entries: broken,
                                           records: archive.records).jsonl()

        #expect(throws: (any Error).self) { try store.importArchive(data, meeting: nil, defaultTitle: "Imported") }
        #expect(try sessionCount(context) == 1)
    }
}

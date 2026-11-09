import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct HarnessSessionStoreTests {
    private func seed(_ context: ModelContext) -> ChatSession {
        let session = ChatSession(meeting: nil, title: "History")
        session.turns = [PersistedChatTurn(id: UUID(), role: .user, text: "Question", usage: nil, costUSD: nil, elapsedSeconds: nil),
                         PersistedChatTurn(id: UUID(), role: .assistant, text: "Answer [0:12]", usage: TokenUsage(promptTokens: 123, completionTokens: 45),
                            costUSD: 0.002, elapsedSeconds: 1.25)]
        context.insert(session)
        return session
    }

    @Test func migrationIsIdempotentRetainsOriginalBytesAndDoesNotInventHistoricalValues() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        let scope = ChatSourceScope(kind: .library, parts: [.summary])
        session.scopeData = JSONStorage.encodeAuthoritative(scope)
        let artifact = ChatDocumentArtifact(title: "Minutes", markdown: "# Decisions", version: 7)
        session.artifactsData = JSONStorage.encodeAuthoritative([artifact])
        let raw = session.turnsData
        let turns = session.turns
        let store = SwiftDataAgentSessionStore(context: context)
        try store.migrate(session)
        let first = try store.snapshot(session)
        try store.migrate(session)
        #expect(session.legacyTurnsData == raw && session.canonicalVersion == 1)
        #expect(first.entries.count == 3 && session.canonicalRevision == first.revision)
        #expect(first.entries.prefix(2).map(\.id) == turns.map { $0.id.uuidString })
        for entry in first.entries.prefix(2) {
            guard case .message(.content(let value)) = entry.payload else { Issue.record("Native message missing"); return }
            #expect(value.timestampMilliseconds == nil && value.identity == nil && value.stopReason == nil)
        }
        let restored = try session.harnessSnapshot()
        #expect(restored.turns.map(\.text) == turns.map(\.text))
        #expect(restored.turns[1].costUSD == 0.002 && restored.turns[1].usage?.promptTokens == 123)
        #expect(restored.scope == scope && restored.artifacts == [artifact])
        #expect(session.harnessRevisions.map(\.version) == [7])
        // Rebuildable caches cannot override canonical entries after conversion.
        session.turnsData = Data("broken cache".utf8); session.artifactsData = Data("broken cache".utf8)
        #expect(try session.harnessSnapshot().turns.map(\.text) == turns.map(\.text))
        #expect(try session.harnessSnapshot().artifacts == [artifact])
    }

    @Test func saveFailureRollsBackOnlyTheAppendGroupAndCanResumeWithoutDuplicates() throws {
        enum Failure: Error { case disk }
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        let raw = session.turnsData
        let failing = SwiftDataAgentSessionStore(context: context, save: { _ in throw Failure.disk })
        #expect(throws: Failure.disk) { try failing.migrate(session) }
        #expect(session.canonicalVersion == nil && session.canonicalRevision == 0 && session.harnessEntries.isEmpty)
        #expect(session.legacyTurnsData == nil && session.turnsData == raw)
        let store = SwiftDataAgentSessionStore(context: context)
        try store.migrate(session)
        let before = try store.snapshot(session)
        var turns = try session.harnessSnapshot().turns
        turns.append(PersistedChatTurn(id: UUID(), role: .user, text: "Next", usage: nil, costUSD: nil, elapsedSeconds: nil))
        #expect(throws: Failure.disk) { try failing.writePresentation(session, turns: turns, scope: nil, artifacts: []) }
        #expect(try store.snapshot(session).entries == before.entries)
        #expect(session.canonicalRevision == before.revision)
        try store.writePresentation(session, turns: turns, scope: nil, artifacts: [])
        #expect(try session.harnessSnapshot().turns.map(\.text) == ["Question", "Answer [0:12]", "Next"])
        #expect(session.harnessEntries.count == 5)
    }

    @Test func changedPresentationBranchesWithoutDeletingOriginalsAndRevisionsRemainImmutable() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        let first = ChatDocumentArtifact(title: "Document", markdown: "First")
        try store.writePresentation(session, turns: session.turns, scope: nil, artifacts: [first])
        let old = try store.snapshot(session)
        var turns = try session.harnessSnapshot().turns
        turns.removeLast()
        let second = ChatDocumentArtifact(id: first.id, title: first.title, markdown: "Second", version: 2)
        try store.writePresentation(session, turns: turns, scope: nil, artifacts: [second])
        let current = try store.snapshot(session)
        #expect(current.entries.count > old.entries.count && current.entries.starts(with: old.entries))
        #expect(try session.harnessSnapshot().turns.count == 1)
        #expect(try session.harnessSnapshot().artifacts == [second])
        #expect(Set(session.harnessRevisions.map(\.version)) == [1, 2])
        let conflicting = ChatDocumentArtifact(id: first.id, title: first.title, markdown: "Changed without revision", version: 2)
        #expect(throws: AgentSessionStoreError.conflict) { try store.writePresentation(session, turns: turns, scope: nil, artifacts: [conflicting]) }
        #expect(try session.harnessSnapshot().artifacts == [second])
        // Saved library documents remain independent of session entry/revision deletion.
        let document = try #require(try ChatArtifactStore(context: context).save(artifactID: first.id, session: session))
        context.delete(session); try context.save()
        #expect(try context.fetchCount(FetchDescriptor<HarnessSessionEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<HarnessArtifactRevision>()) == 0)
        #expect(document.bodyMarkdown == "Second")
    }

    @Test func checksumIndexLeafAndLegacyCorruptionAreSurfacedBeforeConversion() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        session.turnsData = Data("broken".utf8)
        #expect(throws: (any Error).self) { try store.migrate(session) }
        #expect(session.canonicalVersion == nil && session.harnessEntries.isEmpty && session.turnsData == Data("broken".utf8))
        session.turns = []
        try store.migrate(session)
        let row = try #require(session.harnessEntries.first)
        let data = row.payloadData
        row.payloadData = Data("broken".utf8)
        #expect(throws: AgentSessionStoreError.corruptPayload) { try session.harnessSnapshot() }
        row.payloadData = data
        row.ordinal = 99
        #expect(throws: AgentSessionStoreError.invalidGraph) { try store.snapshot(session) }
        row.ordinal = 1
        session.canonicalLeafID = "missing"
        #expect(throws: AgentSessionStoreError.invalidGraph) { try store.snapshot(session) }
    }

    @Test func nativeStoreProtocolChecksRevisionAppendOrderingAndRecoveryMetadata() async throws {
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        try store.migrate(session)
        let before = try await store.load(sessionID: session.id.uuidString)
        let entry = try AgentSessionEntry(sessionID: before.sessionID, id: UUID().uuidString, parentID: before.leafID,
            ordinal: before.entries.count + 1, createdAt: AgentSessionEntry.time(), payload: .custom(type: "checkpoint", data: .null))
        try await store.commit(AgentSessionCommit(sessionID: before.sessionID, expectedRevision: before.revision, entries: [entry], leafID: entry.id))
        await #expect(throws: AgentSessionStoreError.conflict) {
            try await store.commit(AgentSessionCommit(sessionID: before.sessionID, expectedRevision: before.revision, entries: [], leafID: entry.id))
        }
        for kind in [AgentRecoveryRecord.Kind.run, .draft, .queue, .effect] {
            let record = try AgentRecoveryRecord(id: "metadata", kind: kind, data: .object(["known": .bool(true)]))
            try store.put(record, in: session, expectedRevision: session.canonicalRevision)
        }
        #expect(try store.records(session).count == 4)
        let row = try #require(session.harnessRecords.first)
        row.payloadData = Data("corrupt".utf8)
        #expect(throws: AgentSessionStoreError.corruptPayload) { try store.snapshot(session) }
        await #expect(throws: AgentSessionStoreError.notFound) { try await store.load(sessionID: UUID().uuidString) }
    }
    @Test func salvageAndErasureIncludeLibraryWideAndOrphanedHarnessData() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        let artifact = ChatDocumentArtifact(title: "Recovered artifact", markdown: "Retained body")
        try store.writePresentation(session, turns: session.turns, scope: nil, artifacts: [artifact])
        try store.put(AgentRecoveryRecord(id: "draft", kind: .draft, data: .string("Unsent question")),
                      in: session, expectedRevision: session.canonicalRevision)
        let markdown = HarnessStoreSalvage.markdown(sessions: [session], documents: [])
        #expect(markdown.contains("Question") && markdown.contains("Retained body") && markdown.contains("Unsent question"))
        session.harnessEntries.first?.payloadData = Data("corrupt".utf8)
        #expect(HarnessStoreSalvage.markdown(sessions: [session], documents: []).contains("could not be decoded"))
        // Explicit orphan cleanup covers a previous interrupted cascade too.
        let record = try #require(session.harnessRecords.first)
        record.session = nil
        try LibraryEraser.eraseModels(in: context)
        #expect(try context.fetchCount(FetchDescriptor<HarnessSessionEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<HarnessArtifactRevision>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<HarnessSessionRecord>()) == 0)
    }

    @Test func unsupportedStorageEnvelopeIsNotTreatedAsEmptyOrOverwritten() throws {
        let future: [String: Any] = ["version": 2, "payloadChecksum": 0, "payload": Data("intact future data".utf8).base64EncodedString()]
        let raw = try JSONSerialization.data(withJSONObject: future)
        #expect(throws: AgentSessionStoreError.unsupportedVersion) {
            try HarnessPresentationCodec.decode(AgentSessionEntry.self, from: raw)
        }
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        try SwiftDataAgentSessionStore(context: context).migrate(session)
        let row = try #require(session.harnessEntries.first)
        row.payloadData = raw
        #expect(throws: AgentSessionStoreError.unsupportedVersion) { try session.harnessSnapshot() }
        #expect(row.payloadData == raw && session.canonicalVersion == 1)
    }

    @Test func unsupportedLegacyPresentationRoleCannotBecomeAnInventedAssistant() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = seed(context)
        session.turns = [PersistedChatTurn(id: UUID(), role: .system, text: "Legacy system state", usage: nil, costUSD: nil, elapsedSeconds: nil)]
        let original = session.turnsData
        #expect(throws: AgentSessionStoreError.invalidEntry) { try SwiftDataAgentSessionStore(context: context).migrate(session) }
        #expect(session.canonicalVersion == nil && session.turnsData == original && session.harnessEntries.isEmpty)
    }

}

import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct HarnessSessionReviewTests {
    private func seed(_ context: ModelContext) throws -> ChatSession {
        let session = ChatSession(meeting: nil, title: "Recovery", createdAt: Date(timeIntervalSince1970: 100))
        session.turns = [PersistedChatTurn(id: UUID(), role: .user, text: "Readable question", usage: nil, costUSD: nil, elapsedSeconds: nil),
                         PersistedChatTurn(id: UUID(), role: .assistant, text: "Readable answer", usage: nil, costUSD: nil, elapsedSeconds: nil)]
        session.artifactsData = try HarnessPresentationCodec.encode([ChatDocumentArtifact(title: "Intact artifact", markdown: "Readable document")])
        context.insert(session)
        try SwiftDataAgentSessionStore(context: context).migrate(session)
        return session
    }

    @Test func migrationPreservesDateButFirstNewPresentationUpdatesItAndFailureRestoresIt() throws {
        enum Failure: Error { case disk }
        let context = ModelContext(TestModelContainer.make())
        let session = try seed(context)
        #expect(session.updatedAt == Date(timeIntervalSince1970: 100))
        let fresh = ChatSession(meeting: nil, title: "Fresh", createdAt: Date(timeIntervalSince1970: 200))
        context.insert(fresh)
        let turns = try session.harnessSnapshot().turns
        let failing = SwiftDataAgentSessionStore(context: context, save: { _ in throw Failure.disk })
        #expect(throws: Failure.disk) { try failing.writePresentation(fresh, turns: turns, scope: nil, artifacts: []) }
        #expect(fresh.updatedAt == fresh.createdAt)
        try SwiftDataAgentSessionStore(context: context).writePresentation(fresh, turns: turns, scope: nil, artifacts: [])
        #expect(fresh.updatedAt > fresh.createdAt)
        let date = fresh.updatedAt
        try SwiftDataAgentSessionStore(context: context).migrate(fresh)
        #expect(fresh.updatedAt == date)
    }

    @Test func corruptMetadataDoesNotHideMessagesRevisionsOrOtherRecords() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = try seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        for id in ["bad", "good"] {
            try store.put(AgentRecoveryRecord(id: id, kind: .draft, data: .string("Readable draft \(id)")),
                          in: session, expectedRevision: session.canonicalRevision)
        }
        let row = try #require(session.harnessRecords.first { $0.recordID == "bad" })
        row.payloadData = Data("corrupt".utf8)
        #expect(throws: AgentSessionStoreError.corruptPayload) { try session.harnessSnapshot() }
        let output = HarnessStoreSalvage.markdown(sessions: [session], documents: [])
        #expect(output.contains("Readable question") && output.contains("Readable answer"))
        #expect(output.contains("Readable document") && output.contains("Readable draft good"))
        #expect(output.contains("Recovery metadata could not be decoded"))
        #expect(row.payloadData == Data("corrupt".utf8))
    }

    @Test func damagedRowsAreIsolatedAndUncheckedIndexMismatchesAreNotExported() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = try seed(context)
        // Exclude the separately retained legacy copies so only checked row recovery is tested.
        session.legacyTurnsData = nil; session.legacyArtifactsData = nil
        let entry = try #require(session.harnessEntries.first { $0.ordinal == 1 })
        entry.ordinal = 99
        let revision = try #require(session.harnessRevisions.first)
        revision.version = 99
        let output = HarnessStoreSalvage.markdown(sessions: [session], documents: [])
        #expect(!output.contains("Readable question") && output.contains("Readable answer"))
        #expect(!output.contains("Readable document"))
        #expect(output.contains("Retained entry could not be decoded") && output.contains("Artifact revision could not be decoded"))
        #expect(entry.ordinal == 99 && revision.version == 99)
    }

    @Test func checkpointUsesNearestStateOnSelectedPathRatherThanNewerSibling() async throws {
        let context = ModelContext(TestModelContainer.make())
        let session = try seed(context)
        let store = SwiftDataAgentSessionStore(context: context)
        let first = try store.snapshot(session)
        let original = try session.harnessSnapshot()
        let newer = ChatDocumentArtifact(title: "Sibling", markdown: "Other branch")
        try store.writePresentation(session, turns: [], scope: ChatSourceScope(kind: .library, parts: [.summary]), artifacts: [newer])
        let current = try store.snapshot(session)
        let checkpoint = try AgentSessionEntry(sessionID: first.sessionID, id: UUID().uuidString, parentID: first.leafID,
            ordinal: current.entries.count + 1, createdAt: AgentSessionEntry.time(), payload: .custom(type: "checkpoint", data: .null))
        try await store.commit(AgentSessionCommit(sessionID: first.sessionID, expectedRevision: current.revision,
            entries: [checkpoint], leafID: checkpoint.id))
        let restored = try session.harnessSnapshot()
        #expect(restored.turns.map(\.text) == original.turns.map(\.text))
        #expect(restored.scope == original.scope && restored.artifacts == original.artifacts)
        #expect(session.canonicalLeafID == checkpoint.id)
    }

    @Test func legacyRecoverySeparatesArtifactsFromCorruptTurnsAndScope() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = ChatSession(meeting: nil, title: "Legacy")
        context.insert(session)
        session.turnsData = Data("corrupt".utf8); session.scopeData = Data("corrupt".utf8)
        session.artifactsData = try HarnessPresentationCodec.encode([ChatDocumentArtifact(title: "Recovered", markdown: "Readable legacy artifact")])
        let output = HarnessStoreSalvage.markdown(sessions: [session], documents: [])
        #expect(output.contains("Conversation could not be decoded") && output.contains("Readable legacy artifact"))
    }
}

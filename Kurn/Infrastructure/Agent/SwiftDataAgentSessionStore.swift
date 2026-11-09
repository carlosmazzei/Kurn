import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// MainActor owns persistent objects. Generic callers receive only Sendable native values.
@MainActor
struct SwiftDataAgentSessionStore: AgentSessionStore {
    let context: ModelContext
    var save: @MainActor (ModelContext) throws -> Void = { try $0.save() }

    func session(_ id: String) throws -> ChatSession {
        guard let uuid = UUID(uuidString: id) else { throw AgentSessionStoreError.notFound }
        let descriptor = FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == uuid })
        guard let session = try context.fetch(descriptor).first else { throw AgentSessionStoreError.notFound }
        return session
    }

    func load(sessionID: String) async throws -> AgentSessionSnapshot { try snapshot(session(sessionID)) }

    func snapshot(_ session: ChatSession) throws -> AgentSessionSnapshot {
        guard session.canonicalVersion == 1 else { throw AgentSessionStoreError.unsupportedVersion }
        let entries = try session.harnessEntries.map { row -> AgentSessionEntry in
            let value = try HarnessPresentationCodec.decode(AgentSessionEntry.self, from: row.payloadData)
            guard row.sessionID == session.id, row.entryID == value.id, row.parentEntryID == value.parentID,
                  row.ordinal == value.ordinal, row.kindRaw == value.kind, row.createdAtUTC == value.createdAt, row.id == session.id.uuidString + ":" + value.id else { throw AgentSessionStoreError.invalidGraph }
            return value
        }
        guard entries.count == session.canonicalOrdinal, entries.isEmpty == (session.canonicalLeafID == nil), session.canonicalRevision > 0, session.canonicalRevision < Int.max else {
            throw AgentSessionStoreError.invalidGraph
        }
        _ = try records(session)
        try validateRevisions(session)
        let graph = try AgentEntryGraph(sessionID: session.id.uuidString, entries: entries, leafID: session.canonicalLeafID)
        return AgentSessionSnapshot(sessionID: session.id.uuidString, revision: session.canonicalRevision,
                                    leafID: session.canonicalLeafID, entries: graph.entries)
    }

    func commit(_ group: AgentSessionCommit) async throws {
        let target = try session(group.sessionID)
        let current = try snapshot(target)
        guard current.revision == group.expectedRevision else { throw AgentSessionStoreError.conflict }
        guard (current.entries + group.entries).isEmpty == (group.leafID == nil) else { throw AgentSessionStoreError.invalidGraph }
        _ = try AgentEntryGraph(sessionID: group.sessionID, entries: current.entries + group.entries, leafID: group.leafID)
        let rows = try group.entries.map { entry in
            HarnessSessionEntry(session: target, entryID: entry.id, parentEntryID: entry.parentID,
                ordinal: entry.ordinal, kindRaw: entry.kind, createdAtUTC: entry.createdAt, payloadData: try HarnessPresentationCodec.encode(entry))
        }
        let oldLeaf = target.canonicalLeafID
        let oldOrdinal = target.canonicalOrdinal
        let oldRevision = target.canonicalRevision
        do {
            for row in rows { insert(row, into: target) }
            target.canonicalLeafID = group.leafID; target.canonicalOrdinal += rows.count; target.canonicalRevision += 1
            try save(context)
        } catch {
            let ids = Set(rows.map(\.id))
            target.harnessEntries.removeAll { ids.contains($0.id) }
            for row in rows { context.delete(row) }
            target.canonicalLeafID = oldLeaf; target.canonicalOrdinal = oldOrdinal; target.canonicalRevision = oldRevision
            throw error
        }
    }

    func insert(_ row: HarnessSessionEntry, into target: ChatSession) {
        row.session = target
        context.insert(row)
        if !target.harnessEntries.contains(where: { $0.id == row.id }) { target.harnessEntries.append(row) }
    }

    static func projection(_ session: ChatSession) throws -> (turns: [PersistedChatTurn], scope: ChatSourceScope?, artifacts: [ChatDocumentArtifact]) {
        // Reading does not migrate, save or create checkpoints.
        guard session.canonicalVersion == 1 else { throw AgentSessionStoreError.unsupportedVersion }
        let store = SwiftDataAgentSessionStore(context: try requireContext(session))
        let snapshot = try store.snapshot(session)
        let path = try AgentEntryGraph(sessionID: snapshot.sessionID, entries: snapshot.entries, leafID: snapshot.leafID).activePath
        let turns = try path.compactMap { entry -> PersistedChatTurn? in
            if case .message = entry.payload { return try HarnessPresentationCodec.turn(entry) }; return nil
        }
        guard let last = path.last, case .custom(let type, let json) = last.payload, type == HarnessPresentationState.type else {
            throw AgentSessionStoreError.corruptPayload
        }
        let state = try JSONDecoder().decode(HarnessPresentationState.self, from: JSONEncoder().encode(json))
        let revisions = Dictionary(grouping: session.harnessRevisions, by: \.id)
        let artifacts = try state.artifactRevisionIDs.map { id -> ChatDocumentArtifact in
            guard let rows = revisions[id], rows.count == 1, let row = rows.first, row.sessionID == session.id else {
                throw AgentSessionStoreError.corruptPayload
            }
            let artifact = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: row.payloadData)
            guard artifact.id == row.artifactID, artifact.version == row.version,
                  row.id == revisionID(session: session, artifact: artifact), artifact.version > 0 else { throw AgentSessionStoreError.corruptPayload }
            return artifact
        }
        guard Set(artifacts.map(\.id)).count == artifacts.count else { throw AgentSessionStoreError.corruptPayload }
        _ = try ChatDocumentWorkspace(artifacts: artifacts)
        guard Set(turns.map(\.id)).count == turns.count else { throw AgentSessionStoreError.corruptPayload }
        return (turns, state.scope, artifacts)
    }

    static func requireContext(_ session: ChatSession) throws -> ModelContext {
        guard let context = session.modelContext else { throw AgentSessionStoreError.notFound }
        return context
    }
    static func revisionID(session: ChatSession, artifact: ChatDocumentArtifact) -> String {
        session.id.uuidString + ":" + artifact.id.uuidString + ":" + String(artifact.version)
    }
}

import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Tree operations on a saved conversation (NH09). Navigation selects another branch and changes
/// nothing else; fork and clone copy into a new conversation, so the source keeps every branch;
/// labels are detached metadata and a rename changes only the title. Each is one atomic save:
/// a failure, or a change committed by another writer in between, leaves the store as it was.
@MainActor
extension SwiftDataAgentSessionStore {
    /// The conversation's tree as values.
    func tree(_ target: ChatSession) throws -> AgentSessionTree { try AgentSessionTree(snapshot(target)) }

    /// Selects the branch through `entryID`, opening where it was left, if the session is still at
    /// `expectedRevision`. The shown conversation, its sources and its documents follow the branch.
    func navigate(_ target: ChatSession, to entryID: String, expectedRevision: Int) throws {
        let tree = try tree(target)
        guard let leaf = tree.latestLeaf(under: entryID) else { throw AgentSessionStoreError.notFound }
        let commit = try tree.navigation(to: leaf, expectedRevision: expectedRevision)
        guard target.canonicalRevision == commit.expectedRevision else { throw AgentSessionStoreError.conflict }
        guard leaf != target.canonicalLeafID else { return }
        let old = PresentationCheckpoint(target)
        do {
            target.canonicalLeafID = leaf
            let projection = try Self.projection(target)
            let cache = try PresentationCache(turns: projection.turns, scope: projection.scope, artifacts: projection.artifacts)
            target.turnsData = cache.turns; target.scopeData = cache.scope; target.artifactsData = cache.artifacts
            target.canonicalRevision += 1
            try save(context)
        } catch {
            old.restore(target)
            throw error
        }
    }

    /// Labels `entryID` (nil removes its label), leaving the selected branch where it is.
    func label(_ target: ChatSession, entry entryID: String, as label: String?) throws {
        let snapshot = try snapshot(target)
        let entry = try AgentSessionTree(snapshot).labelEntry(label, on: entryID)
        try commitNow(AgentSessionCommit(sessionID: snapshot.sessionID, expectedRevision: snapshot.revision,
                                         entries: [entry], leafID: snapshot.leafID))
    }

    /// Leaves the turns `leavingOut` out of what later runs replay, or includes `including` again
    /// (`AgentContextEdit`): the conversation shown, the log and recorded usage are unchanged.
    func editContext(_ target: ChatSession, leavingOut: [UUID] = [], including: [UUID] = []) throws {
        guard !leavingOut.isEmpty || !including.isEmpty else { return }
        let snapshot = try snapshot(target)
        let edit = AgentContextEdit(removedMessageIDs: leavingOut.map(\.uuidString), restoredMessageIDs: including.map(\.uuidString))
        try commitNow(AgentSessionCommit(sessionID: snapshot.sessionID, expectedRevision: snapshot.revision,
            entries: [try edit.entry(sessionID: snapshot.sessionID, ordinal: snapshot.entries.count + 1)], leafID: snapshot.leafID))
    }

    /// Renames the conversation. An empty title is ignored.
    func rename(_ target: ChatSession, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != target.title else { return }
        let old = target.title
        target.title = String(trimmed.prefix(120))
        do { try save(context) } catch { target.title = old; throw error }
    }

    /// A new conversation holding `source`'s path through `entryID` with the runs that answered
    /// it, its labels and the document revisions it shows; nil when there is nothing before it.
    /// A fork passes the entry before the question it starts from and the question as
    /// `askedAt`, a clone the selected leaf. The source is unchanged.
    func copy(_ source: ChatSession, through entryID: String?, title: String, askedAt question: String? = nil) throws -> ChatSession? {
        guard let entryID else { return nil }
        let tree = try tree(source)
        let target = ChatSession(meeting: source.meeting, title: title)
        let newID = target.id.uuidString
        var entries = try tree.copy(through: entryID, into: newID).map { try Self.rebased($0, from: source, to: target) }
        var leaf = entryID
        // The copy ends on the conversation's state as it was at that point. For a fork, that is the
        // state saved with the question itself (its sources and documents when it was asked): a
        // question asked again is written under the last common message, so the state saved there
        // may predate later changes. Otherwise it is the state saved right there, else the nearest
        // one before it.
        let isState = { (entry: AgentSessionEntry) in entry.kind == HarnessPresentationState.type }
        let shown = tree.activePath
        let askedWith = question.flatMap { id in shown.firstIndex { $0.id == id } }.flatMap { shown[($0 + 1)...].first(where: isState) }
        if askedWith != nil || tree.entry(entryID).map(isState) != true {
            let saved = askedWith ?? tree.entries.last { $0.parentID == entryID && isState($0) } ?? tree.path(to: entryID).last(where: isState)
            guard let saved else { throw AgentSessionStoreError.corruptPayload }
            let state = try AgentSessionEntry(sessionID: newID, id: UUID().uuidString, parentID: entryID,
                ordinal: entries.count + 1, createdAt: AgentSessionEntry.time(), payload: saved.payload, metadata: saved.metadata)
            entries.append(try Self.rebased(state, from: source, to: target))
            leaf = state.id
        }
        _ = try AgentEntryGraph(sessionID: newID, entries: entries, leafID: leaf)
        let referenced = Set(entries.flatMap(Self.revisionIDs))
        let revisions = source.harnessRevisions.filter { referenced.contains(Self.rebased($0.id, from: source, to: target)) }
        context.insert(target)
        do {
            for entry in entries {
                insert(HarnessSessionEntry(session: target, entryID: entry.id, parentEntryID: entry.parentID, ordinal: entry.ordinal,
                    kindRaw: entry.kind, createdAtUTC: entry.createdAt, payloadData: try HarnessPresentationCodec.encode(entry)), into: target)
            }
            for row in revisions {
                let copied = HarnessArtifactRevision(session: target, artifactID: row.artifactID, version: row.version,
                    payloadData: row.payloadData, id: Self.rebased(row.id, from: source, to: target))
                copied.session = target
                context.insert(copied)
            }
            target.canonicalVersion = 1; target.canonicalLeafID = leaf
            target.canonicalOrdinal = entries.count; target.canonicalRevision = 1
            let projection = try Self.projection(target)
            let cache = try PresentationCache(turns: projection.turns, scope: projection.scope, artifacts: projection.artifacts)
            target.turnsData = cache.turns; target.scopeData = cache.scope; target.artifactsData = cache.artifacts
            try save(context)
            return target
        } catch {
            context.delete(target)
            throw error
        }
    }

    private static func rebased(_ entry: AgentSessionEntry, from source: ChatSession, to target: ChatSession) throws -> AgentSessionEntry {
        try rebased(entry, from: source.id.uuidString, to: target.id.uuidString)
    }

    private static func rebased(_ revisionID: String, from source: ChatSession, to target: ChatSession) -> String {
        rebased(revisionID, from: source.id.uuidString, to: target.id.uuidString)
    }

    /// `entry` with its presentation state's revision IDs moved from session `source` to `target`.
    static func rebased(_ entry: AgentSessionEntry, from source: String, to target: String) throws -> AgentSessionEntry {
        guard case .custom(HarnessPresentationState.type, let data) = entry.payload else { return entry }
        var state = try JSONDecoder().decode(HarnessPresentationState.self, from: JSONEncoder().encode(data))
        state.artifactRevisionIDs = state.artifactRevisionIDs.map { rebased($0, from: source, to: target) }
        return try AgentSessionEntry(sessionID: entry.sessionID, id: entry.id, parentID: entry.parentID, ordinal: entry.ordinal,
            createdAt: entry.createdAt, payload: .custom(type: HarnessPresentationState.type, data: HarnessPresentationCodec.json(state)),
            metadata: entry.metadata)
    }

    static func rebased(_ revisionID: String, from source: String, to target: String) -> String {
        let prefix = source + ":"
        guard revisionID.hasPrefix(prefix) else { return revisionID }
        return target + ":" + revisionID.dropFirst(prefix.count)
    }

    static func revisionIDs(_ entry: AgentSessionEntry) -> [String] {
        guard case .custom(HarnessPresentationState.type, let data) = entry.payload,
              let state = try? JSONDecoder().decode(HarnessPresentationState.self, from: JSONEncoder().encode(data)) else { return [] }
        return state.artifactRevisionIDs
    }
}

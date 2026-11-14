import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Asking a question again in its place (NH09): the conversation goes back to just before the
/// question, so the next question saved is another version beside it ("‹ n of m ›"). Nothing is
/// removed; the question and everything after it stay on their own branch.
@MainActor
extension SwiftDataAgentSessionStore {
    /// Selects the conversation as it was when the question `entryID` was asked, without it: its
    /// earlier turns, and the sources and documents saved with the question. One atomic save, made
    /// only if the session is still at `expectedRevision`.
    func rewind(_ target: ChatSession, before entryID: String, expectedRevision: Int) throws {
        guard target.canonicalRevision == expectedRevision else { throw AgentSessionStoreError.conflict }
        let snapshot = try snapshot(target)
        let tree = try AgentSessionTree(snapshot)
        guard let question = tree.entry(entryID), !AgentSessionTree.isRunEntry(question),
              case .message = question.payload else { throw AgentSessionStoreError.notFound }
        let isState = { (entry: AgentSessionEntry) in entry.kind == HarnessPresentationState.type }
        // The state saved with the question (as a fork uses), else the nearest one before it.
        let shown = tree.activePath
        let askedWith = shown.firstIndex { $0.id == entryID }.flatMap { shown[($0 + 1)...].first(where: isState) }
            ?? tree.path(to: question.parentID).last(where: isState)
        guard let saved = askedWith else { throw AgentSessionStoreError.corruptPayload }
        let state = try AgentSessionEntry(sessionID: snapshot.sessionID, id: UUID().uuidString, parentID: question.parentID,
            ordinal: snapshot.entries.count + 1, createdAt: AgentSessionEntry.time(), payload: saved.payload, metadata: saved.metadata)
        _ = try AgentEntryGraph(sessionID: snapshot.sessionID, entries: snapshot.entries + [state], leafID: state.id)
        let row = HarnessSessionEntry(session: target, entryID: state.id, parentEntryID: state.parentID, ordinal: state.ordinal,
            kindRaw: state.kind, createdAtUTC: state.createdAt, payloadData: try HarnessPresentationCodec.encode(state))
        let old = PresentationCheckpoint(target)
        do {
            insert(row, into: target)
            target.canonicalLeafID = state.id
            target.canonicalOrdinal += 1
            target.canonicalRevision += 1
            let projection = try Self.projection(target)
            let cache = try PresentationCache(turns: projection.turns, scope: projection.scope, artifacts: projection.artifacts)
            target.turnsData = cache.turns; target.scopeData = cache.scope; target.artifactsData = cache.artifacts
            try save(context)
        } catch {
            target.harnessEntries.removeAll { $0.id == row.id }
            context.delete(row)
            old.restore(target)
            throw error
        }
    }
}

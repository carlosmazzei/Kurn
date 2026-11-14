import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Undoing a document change: the document gets back the version it had before its latest one, as
/// a new version (`ChatDocumentEdit.restore`). Nothing is removed, so the change undone stays saved
/// and can itself be restored.
@MainActor
extension SwiftDataAgentSessionStore {
    /// The version `artifactID` had before the one shown: the revision the shown one replaced, as
    /// the state that introduced it recorded (`HarnessPresentationState.predecessors`). The link is
    /// followed wherever that state sits on the tree (a document change rewrites its question as a
    /// sibling, so the earlier state is beside the shown path), and never guessed from another
    /// branch. Nil when nothing recorded it: a document never changed, or one changed before the
    /// link was kept.
    func previousVersion(of artifactID: UUID, in target: ChatSession) throws -> ChatDocumentArtifact? {
        let snapshot = try snapshot(target)
        let tree = try AgentSessionTree(snapshot)
        guard let shown = try tree.activePath.last(where: { $0.kind == HarnessPresentationState.type })
            .flatMap(HarnessPresentationState.decoded) else { return nil }
        let rows = Dictionary(target.harnessRevisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let currentID = shown.artifactRevisionIDs.first(where: { rows[$0]?.artifactID == artifactID }) else { return nil }
        var previousID: String?
        for entry in snapshot.entries.sorted(by: { $0.ordinal < $1.ordinal }) {
            if let link = try HarnessPresentationState.decoded(entry)?.predecessors?[currentID] { previousID = link }
        }
        guard let previousID, let row = rows[previousID] else { return nil }
        let artifact = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: row.payloadData)
        guard artifact.id == artifactID, artifact.version == row.version, row.artifactID == artifactID else {
            throw AgentSessionStoreError.corruptPayload
        }
        return artifact
    }

    /// Restores the version before the latest one of `artifactID`, in one save made only if the
    /// session is still at `expectedRevision`. Returns the conversation's documents after it.
    func undoLastChange(of artifactID: UUID, in target: ChatSession, expectedRevision: Int) throws -> [ChatDocumentArtifact] {
        guard target.canonicalRevision == expectedRevision else { throw AgentSessionStoreError.conflict }
        guard let earlier = try previousVersion(of: artifactID, in: target) else { throw AgentSessionStoreError.notFound }
        let shown = try Self.projection(target)
        let change = try ChatDocumentEdit.restore(earlier).applying(to: shown.artifacts)
        try writePresentation(target, turns: shown.turns, scope: shown.scope, artifacts: change.artifacts)
        return try target.harnessSnapshot().artifacts
    }
}

import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Undoing a document change: the document gets back the version it had before its latest one, as
/// a new version (`ChatDocumentEdit.restore`). Nothing is removed, so the change undone stays saved
/// and can itself be restored.
@MainActor
extension SwiftDataAgentSessionStore {
    /// The version `artifactID` had before the one shown: the revision the shown one replaced on this
    /// branch, as the shown state carries it (`HarnessPresentationState.predecessors`). The earlier
    /// revision can sit in a state beside the shown path (a document change rewrites its question
    /// as a sibling); the link reaches it without searching the tree, so another branch that reused
    /// the same revision never decides. Nil when nothing recorded it: a document never changed, or
    /// one changed before the link was kept.
    func previousVersion(of artifactID: UUID, in target: ChatSession) throws -> ChatDocumentArtifact? {
        let tree = try AgentSessionTree(try snapshot(target))
        guard let shown = try tree.activePath.last(where: { $0.kind == HarnessPresentationState.type })
            .flatMap(HarnessPresentationState.decoded) else { return nil }
        let rows = Dictionary(target.harnessRevisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let currentID = shown.artifactRevisionIDs.first(where: { rows[$0]?.artifactID == artifactID }) else { return nil }
        guard let previousID = shown.predecessors?[currentID], let row = rows[previousID] else { return nil }
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

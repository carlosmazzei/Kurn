import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Undoing a document change: the document gets back the version it had before its latest one, as
/// a new version (`ChatDocumentEdit.restore`). Nothing is removed, so the change undone stays saved
/// and can itself be restored.
@MainActor
extension SwiftDataAgentSessionStore {
    /// The newest version of `artifactID` older than the one shown, from the states of the branch
    /// shown: what the conversation held before its latest change. Nil when there is none.
    func previousVersion(of artifactID: UUID, in target: ChatSession) throws -> ChatDocumentArtifact? {
        guard let current = try Self.projection(target).artifacts.first(where: { $0.id == artifactID }) else { return nil }
        let tree = try AgentSessionTree(try snapshot(target))
        let revisions = Dictionary(grouping: target.harnessRevisions, by: \.id)
        for entry in tree.activePath.reversed() where entry.kind == HarnessPresentationState.type {
            guard case .custom(_, let json) = entry.payload else { continue }
            let state = try JSONDecoder().decode(HarnessPresentationState.self, from: JSONEncoder().encode(json))
            for id in state.artifactRevisionIDs {
                guard let row = revisions[id]?.first, row.artifactID == artifactID, row.version < current.version else { continue }
                let artifact = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: row.payloadData)
                guard artifact.id == artifactID, artifact.version == row.version else { throw AgentSessionStoreError.corruptPayload }
                return artifact
            }
        }
        return nil
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

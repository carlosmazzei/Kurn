import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Undoing a document change: the document gets back the version it had before its latest one, as
/// a new version (`ChatDocumentEdit.restore`). Nothing is removed, so the change undone stays saved
/// and can itself be restored.
@MainActor
extension SwiftDataAgentSessionStore {
    /// The version `artifactID` had before the one shown: every change adds one to the version, so
    /// it is version − 1. When branches wrote that version differently, the revision closest to the
    /// branch shown wins (the deepest common ancestor, then the newest). The tree is searched, not
    /// only the shown path: a document change rewrites the question it belongs to as a sibling, so
    /// the state that held the earlier version can sit beside the path rather than on it.
    func previousVersion(of artifactID: UUID, in target: ChatSession) throws -> ChatDocumentArtifact? {
        guard let current = try Self.projection(target).artifacts.first(where: { $0.id == artifactID }),
              current.version > 1 else { return nil }
        let candidates = Dictionary(target.harnessRevisions
            .filter { $0.artifactID == artifactID && $0.version == current.version - 1 }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        guard !candidates.isEmpty else { return nil }
        let snapshot = try snapshot(target)
        let tree = try AgentSessionTree(snapshot)
        let depth = Dictionary(uniqueKeysWithValues: tree.activePath.enumerated().map { ($1.id, $0) })
        var best: (depth: Int, ordinal: Int, row: HarnessArtifactRevision)?
        for entry in snapshot.entries where entry.kind == HarnessPresentationState.type {
            guard case .custom(_, let json) = entry.payload else { continue }
            let state = try JSONDecoder().decode(HarnessPresentationState.self, from: JSONEncoder().encode(json))
            guard let row = state.artifactRevisionIDs.lazy.compactMap({ candidates[$0] }).first else { continue }
            let shared = tree.path(to: entry.id).compactMap { depth[$0.id] }.max() ?? -1
            if best.map({ (shared, entry.ordinal) > ($0.depth, $0.ordinal) }) ?? true {
                best = (shared, entry.ordinal, row)
            }
        }
        guard let row = best?.row ?? candidates.values.first else { return nil }
        let artifact = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: row.payloadData)
        guard artifact.id == artifactID, artifact.version == row.version else { throw AgentSessionStoreError.corruptPayload }
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

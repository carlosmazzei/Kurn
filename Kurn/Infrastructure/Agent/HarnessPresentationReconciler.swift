import AgentHarness
import Foundation
import KurnCore

/// Compatibility UI saves may race a known committed tool while cancellation is settling.
/// Preserve newer committed artifacts/references; explicit branch writes use the store directly.
enum HarnessPresentationReconciler {
    static func preserve(turns: [PersistedChatTurn], artifacts: [ChatDocumentArtifact],
                         committed: (turns: [PersistedChatTurn], artifacts: [ChatDocumentArtifact])) throws
        -> (turns: [PersistedChatTurn], artifacts: [ChatDocumentArtifact]) {
        guard Set(turns.map(\.id)).count == turns.count, Set(artifacts.map(\.id)).count == artifacts.count else {
            throw AgentSessionStoreError.invalidEntry
        }
        var documents = Dictionary(uniqueKeysWithValues: committed.artifacts.map { ($0.id, $0) })
        for artifact in artifacts where artifact.version >= (documents[artifact.id]?.version ?? 0) { documents[artifact.id] = artifact }
        let saved = Dictionary(uniqueKeysWithValues: committed.turns.map { ($0.id, $0) })
        let reconciled = turns.map { turn -> PersistedChatTurn in
            guard let old = saved[turn.id] else { return turn }
            var result = turn
            var references = turn.artifacts ?? []
            var origins = turn.artifactOrigins ?? [:]
            for reference in old.artifacts ?? [] where reference.version > (references.first { $0.id == reference.id }?.version ?? 0) {
                references = ChatArtifactReference.merging(references, with: [reference])
                if let origin = old.artifactOrigins?[reference.id] { origins[reference.id] = origin }
            }
            if !references.isEmpty { result.artifacts = references }
            if !origins.isEmpty { result.artifactOrigins = origins }
            return result
        }
        return (reconciled, documents.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}

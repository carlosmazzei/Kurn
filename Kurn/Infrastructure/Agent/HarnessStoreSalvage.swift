import AgentHarness
import Foundation
import KurnCore

/// Markdown recovery only; it does not import, migrate, resume runs or execute queued work.
@MainActor
enum HarnessStoreSalvage {
    enum Component: String, CaseIterable {
        case retainedEntry = "retained_entry", artifactRevision = "artifact_revision", recoveryMetadata = "recovery_metadata"
        case legacyConversation = "legacy_conversation", legacyArtifacts = "legacy_artifacts", conversation, artifacts, artifact

        func displayName(bundle: Bundle = .main) -> String {
            NSLocalizedString("store_recovery.chat.\(rawValue)", bundle: bundle, comment: "Component in recovered conversation export")
        }
    }

    static func markdown(sessions: [ChatSession], documents: [GeneratedDocument]) -> String {
        var out = "\n# Saved conversations\n"
        for session in sessions.sorted(by: { $0.createdAt < $1.createdAt }) {
            out += "\n## \(session.title)\n\nSession: \(session.id)\n"
            if session.canonicalVersion != nil {
                // Recovery is deliberately independent of the strict live snapshot. One damaged
                // draft, revision or entry must not hide other verifiable rows. These are retained
                // records, not a claim that the active path of a damaged graph is valid.
                out += "\n### Retained message history\n"
                for row in session.harnessEntries.sorted(by: { $0.ordinal < $1.ordinal }) {
                    out += recover(.retainedEntry) {
                        let entry = try SwiftDataAgentSessionStore.checkedEntry(row, session: session)
                        let header = "\nEntry \(entry.id), parent \(entry.parentID ?? "root"), ordinal \(entry.ordinal)\n"
                        switch entry.payload {
                        case .message(.content(let value)): return header + value.text + "\n"
                        case .message(.tool(let value)): return header + value.text + "\n"
                        case .custom(let type, let data): return header + "\(type)\n\n```json\n\(try data.encodedString())\n```\n"
                        default: throw AgentSessionStoreError.corruptPayload
                        }
                    }
                }
                for row in session.harnessRevisions.sorted(by: { $0.version < $1.version }) {
                    out += recover(.artifactRevision) {
                        artifact(try SwiftDataAgentSessionStore.checkedRevision(row, session: session))
                    }
                }
                for row in session.harnessRecords.sorted(by: { $0.id < $1.id }) {
                    out += recover(.recoveryMetadata) {
                        let value = try SwiftDataAgentSessionStore.checkedRecord(row, session: session)
                        return "\n### Stored \(value.kind.rawValue) metadata: \(value.id)\n\n```json\n\(try value.data.encodedString())\n```\n"
                    }
                }
                // Explicitly label pre-conversion history; it may predate the retained entries.
                if let data = session.legacyTurnsData { out += turns(data, label: .legacyConversation) }
                if let data = session.legacyArtifactsData { out += artifacts(data, label: .legacyArtifacts) }
            } else {
                out += turns(session.turnsData, label: .conversation)
                if let data = session.artifactsData { out += artifacts(data, label: .artifacts) }
            }
        }
        for document in documents.sorted(by: { $0.createdAt < $1.createdAt }) {
            out += "\n# Saved document: \(document.title)\n\n\(document.bodyMarkdown)\n"
        }
        return out
    }

    private static func recover(_ component: Component, read: () throws -> String) -> String {
        do { return try read() }
        catch { return "\n[\(warning(component))]\n" }
    }

    static func warning(_ component: Component, bundle: Bundle = .main) -> String {
        String(format: NSLocalizedString("store_recovery.chat.decode_warning", bundle: bundle,
            comment: "Recovery warning; argument is the localized component name"), component.displayName(bundle: bundle))
    }

    private static func turns(_ data: Data, label: Component) -> String {
        recover(label) {
            let values = try HarnessPresentationCodec.decode([PersistedChatTurn].self, from: data)
            return "\n### \(label.displayName())\n" + values.map { "\n### \($0.role == .user ? "User" : "Assistant")\n\n\($0.text)\n" }.joined()
        }
    }

    private static func artifacts(_ data: Data, label: Component) -> String {
        recover(label) {
            try HarnessPresentationCodec.decode([ChatDocumentArtifact].self, from: data).map { value in
                recover(.artifact) {
                    _ = try ChatDocumentWorkspace(artifacts: [value])
                    return artifact(value)
                }
            }.joined()
        }
    }

    private static func artifact(_ value: ChatDocumentArtifact) -> String {
        "\n### \(value.title) (revision \(value.version))\n\n\(value.markdown)\n"
    }
}

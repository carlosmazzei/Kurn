import AgentHarness
import Foundation
import KurnCore

/// Markdown recovery only; it does not import, migrate, resume runs or execute queued work.
@MainActor
enum HarnessStoreSalvage {
    static func markdown(sessions: [ChatSession], documents: [GeneratedDocument]) -> String {
        var out = "\n# Saved conversations\n"
        for session in sessions.sorted(by: { $0.createdAt < $1.createdAt }) {
            out += "\n## \(session.title)\n\nSession: \(session.id)\n"
            do {
                let snapshot = try session.harnessSnapshot()
                for turn in snapshot.turns { out += "\n### \(turn.role == .user ? "User" : "Assistant")\n\n\(turn.text)\n" }
                if session.canonicalVersion != nil {
                    // Include retained sibling messages/revisions, not just the selected path.
                    let store = SwiftDataAgentSessionStore(context: try SwiftDataAgentSessionStore.requireContext(session))
                    let entries = try store.snapshot(session).entries
                    out += "\n### Retained message history\n"
                    for entry in entries {
                        if case .message(let message) = entry.payload {
                            out += "\nEntry \(entry.id), parent \(entry.parentID ?? "root"), ordinal \(entry.ordinal)\n"
                            switch message {
                            case .content(let value): out += value.text + "\n"
                            case .tool(let value): out += value.text + "\n"
                            default: break
                            }
                        }
                    }
                    for row in session.harnessRevisions.sorted(by: { $0.version < $1.version }) {
                        let value = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: row.payloadData)
                        out += "\n### \(value.title) (revision \(value.version))\n\n\(value.markdown)\n"
                    }
                    for record in try store.records(session) {
                        out += "\n### Stored \(record.kind.rawValue) metadata: \(record.id)\n\n```json\n\(try record.data.encodedString())\n```\n"
                    }
                } else {
                    for value in snapshot.artifacts { out += "\n### \(value.title) (revision \(value.version))\n\n\(value.markdown)\n" }
                }
            } catch {
                out += "\n[Conversation payload could not be decoded. Original store bytes are unchanged.]\n"
            }
        }
        for document in documents.sorted(by: { $0.createdAt < $1.createdAt }) {
            out += "\n# Saved document: \(document.title)\n\n\(document.bodyMarkdown)\n"
        }
        return out
    }
}

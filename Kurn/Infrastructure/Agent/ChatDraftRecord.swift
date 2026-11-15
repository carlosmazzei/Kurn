import AgentHarness
import Foundation

/// The composer's unsent text for a saved conversation (A68), kept as the session's `.draft`
/// recovery record so text typed before the app went to the background survives the process. It is
/// data only: a reopened conversation puts it back in the composer and never sends it.
enum ChatDraftRecord {
    static let id = "composer"

    @MainActor
    static func save(_ text: String, in session: ChatSession, store: SwiftDataAgentSessionStore) throws {
        try store.put(AgentRecoveryRecord(id: id, kind: .draft, data: .object(["text": .string(text)])), in: session,
                      expectedRevision: session.canonicalRevision)
    }

    /// The saved text, empty when the session has none or it cannot be read.
    @MainActor
    static func load(from session: ChatSession, store: SwiftDataAgentSessionStore) -> String {
        guard let record = (try? store.records(session))?.first(where: { $0.kind == .draft && $0.id == id }),
              case .object(let fields) = record.data, case .string(let text)? = fields["text"] else { return "" }
        return text
    }
}

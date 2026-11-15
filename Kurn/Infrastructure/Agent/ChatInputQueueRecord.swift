import AgentHarness
import Foundation

/// A conversation's queued input (NH08), kept as the session's `.queue` recovery record so input
/// the person queued is saved before it is acknowledged. The record holds the complete lists; it
/// never schedules anything: a reopened conversation hands what it holds back to the composer.
enum ChatInputQueueRecord {
    static let id = "pending"

    @MainActor
    static func save(_ snapshot: AgentInputQueue.Snapshot, in session: ChatSession,
                     store: SwiftDataAgentSessionStore) throws {
        let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot))
        try store.put(AgentRecoveryRecord(id: id, kind: .queue, data: data), in: session,
                      expectedRevision: session.canonicalRevision)
    }

    /// The lists the session holds, empty when it has none or they cannot be read.
    @MainActor
    static func load(from session: ChatSession, store: SwiftDataAgentSessionStore) -> AgentInputQueue.Snapshot {
        guard let record = (try? store.records(session))?.first(where: { $0.kind == .queue && $0.id == id }),
              let data = try? JSONEncoder().encode(record.data),
              let snapshot = try? JSONDecoder().decode(AgentInputQueue.Snapshot.self, from: data) else {
            return AgentInputQueue.Snapshot()
        }
        return snapshot
    }
}

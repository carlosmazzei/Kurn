import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Launch reconciliation for chat runs (NH05). No run is live when a store opens, so every
/// `ChatRunRecord` still `.running` was cut off with its process. Marking it `.interrupted` is all
/// the repair there is: the question was saved before the run started and reopens as retryable,
/// and committed document effects already carry their own receipts. Nothing is re-sent.
@MainActor
enum ChatRunRecovery {
    /// Returns the number of runs marked interrupted. A session whose records cannot be read is
    /// left untouched and reported; it never stops the sweep of the others.
    @discardableResult
    static func sweep(context: ModelContext) -> Int {
        let sessions = (try? context.fetch(FetchDescriptor<ChatSession>())) ?? []
        let store = SwiftDataAgentSessionStore(context: context)
        var interrupted = 0
        for session in sessions where !session.harnessRecords.isEmpty {
            do {
                for record in try store.records(session) {
                    guard var run = ChatRunRecord(record), run.state == .running else { continue }
                    run.state = .interrupted
                    try store.put(run.record(), in: session, expectedRevision: session.canonicalRevision)
                    interrupted += 1
                    ReliabilityLog.record(ReliabilityEvent(
                        operationID: OperationID(String(run.runID.prefix(8))), operation: "meeting_chat",
                        stage: "launch_recovery", outcome: .cancelled, code: "run_interrupted"
                    ))
                }
            } catch {
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: OperationID(String(session.id.uuidString.prefix(8))), operation: "meeting_chat",
                    stage: "launch_recovery", outcome: .failed, code: "run_recovery_failed"
                ))
            }
        }
        return interrupted
    }

    /// The question turns whose runs were interrupted, so a reopened conversation can say why
    /// its question is unanswered. Unreadable records contribute nothing: this only explains.
    static func interruptedQuestionIDs(in session: ChatSession, context: ModelContext) -> Set<UUID> {
        guard let records = try? SwiftDataAgentSessionStore(context: context).records(session) else { return [] }
        return Set(records.compactMap(ChatRunRecord.init).filter { $0.state == .interrupted }.map(\.questionTurnID))
    }
}

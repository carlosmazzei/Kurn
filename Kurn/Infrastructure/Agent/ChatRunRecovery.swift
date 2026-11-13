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
        Set(interruptedRuns(in: session, context: context).keys)
    }

    /// Each interrupted question turn with the run that last left it unanswered (the latest by
    /// start, when a retry was cut off too).
    static func interruptedRuns(in session: ChatSession, context: ModelContext) -> [UUID: String] {
        guard let records = try? SwiftDataAgentSessionStore(context: context).records(session) else { return [:] }
        let interrupted = records.compactMap(ChatRunRecord.init).filter { $0.state == .interrupted }
        return Dictionary(grouping: interrupted, by: \.questionTurnID).compactMapValues { runs in
            runs.max { $0.startedAt < $1.startedAt }?.runID
        }
    }

    /// A reopened conversation's turns, with the interrupted run's canonical history shown under
    /// the question it left unanswered: the steps and usage `AgentRunTrace.restoring` rebuilds
    /// from the run's branch. Only the retryable question (the last turn, still unanswered and
    /// with no steps of its own) gains them. Read-only: nothing is migrated or saved, and a branch
    /// that cannot be read leaves the turns as they were.
    static func restoringInterruptedRun(in turns: [PersistedChatTurn], session: ChatSession,
                                        context: ModelContext) -> (turns: [PersistedChatTurn], interrupted: Set<UUID>) {
        let runs = interruptedRuns(in: session, context: context)
        var turns = turns
        guard let last = turns.last, last.role == .user, last.steps?.isEmpty ?? true, let runID = runs[last.id],
              let entries = try? SwiftDataAgentSessionStore(context: context).snapshot(session).entries,
              let trace = AgentRunTrace.restoring(run: runID, from: entries) else { return (turns, Set(runs.keys)) }
        turns[turns.count - 1].steps = trace.steps.isEmpty ? nil : trace.steps
        if trace.hasUsage, last.usage == nil {
            turns[turns.count - 1].usage = TokenUsage(promptTokens: trace.usage.inputTokens,
                                                      completionTokens: trace.usage.outputTokens)
        }
        return (turns, Set(runs.keys))
    }
}

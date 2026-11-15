import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Launch reconciliation for chat runs (NH05). No run is live when a store opens, so every
/// `ChatRunRecord` still `.running` was cut off with its process and is marked `.interrupted`:
/// the question was saved before the run started and reopens as retryable, and committed
/// document effects already carry their own receipts. Any run's branch that nothing closed —
/// that process's, or one whose own end entry failed to save — gets the end entry it is missing
/// (`ChatRunBranch.closeIfOpen`). Nothing is re-sent.
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
                    guard var run = ChatRunRecord(record) else { continue }
                    if run.state == .running {
                        run.state = .interrupted
                        try store.put(run.record(), in: session, expectedRevision: session.canonicalRevision)
                        interrupted += 1
                        ReliabilityLog.record(ReliabilityEvent(
                            operationID: OperationID(String(run.runID.prefix(8))), operation: "meeting_chat",
                            stage: "launch_recovery", outcome: .cancelled, code: "run_interrupted"
                        ))
                    }
                    // Evidence is closed, not deleted: a branch nothing ended gets the end the run
                    // could not write — `interrupted` for a dead process, `persistenceFailed` for a
                    // run that settled but could not save its own end.
                    let end = run.state == .interrupted ? "interrupted" : "persistenceFailed"
                    // Each branch on its own: one that cannot be closed now stays for the next
                    // launch without keeping the session's other runs from being reconciled.
                    if (try? ChatRunBranch.closeIfOpen(runID: run.runID, end: end, in: session, store: store)) == true {
                        ReliabilityLog.record(ReliabilityEvent(
                            operationID: OperationID(String(run.runID.prefix(8))), operation: "meeting_chat",
                            stage: "launch_recovery", outcome: .succeeded, code: "run_branch_closed"
                        ))
                    }
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
    /// with no steps of its own) gains them. Restoring writes nothing, and a branch that cannot be
    /// read leaves the turns as they were. A later save of the conversation (a scope change, the
    /// next question) keeps the shown steps on the question, as it does a stopped run's; the next
    /// reopen then finds steps there and restores nothing again.
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

    /// The run whose interruption a reopened conversation may resume automatically, once: the
    /// interrupted run of the retryable question (the last turn, unanswered), provided it
    /// committed no document change (a resumed run would call the tool again under a new
    /// invocation identity no receipt matches), was not itself a resume, and has not been
    /// resumed already — its resume command is durable in the log
    /// (`ChatRunBranch.resumeCommand(for:)`), so a resume never repeats across launches.
    static func resumableInterruptedRun(in turns: [PersistedChatTurn], session: ChatSession,
                                        context: ModelContext) -> String? {
        guard let last = turns.last, last.role == .user,
              let runID = interruptedRuns(in: session, context: context)[last.id],
              let entries = try? SwiftDataAgentSessionStore(context: context).snapshot(session).entries else { return nil }
        let run = entries.filter { $0.runID == runID }
        guard !run.contains(where: { $0.commandID?.hasPrefix(ChatRunBranch.resumePrefix) == true }),
              !entries.contains(where: { $0.commandID == ChatRunBranch.resumeCommand(for: runID) }) else { return nil }
        let changedDocument = run.contains { entry in
            guard case .message(.tool(let result)) = entry.payload else { return false }
            return !result.isError && ChatRunBranch.documentTools.contains(result.invocation.toolName)
        }
        return changedDocument ? nil : runID
    }
}

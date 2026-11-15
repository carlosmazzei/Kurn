import AgentHarness
import Foundation
import KurnCore

/// Resuming a reply that stopped without the user asking (NH05): the background wind-down's
/// stop is resumed on return to the foreground, and a dead process's interruption when its
/// conversation is reopened. Each resumes once, from the saved question; nothing of the stopped
/// run is replayed, and a run that committed a document change is left for the user's Retry.
extension MeetingChatViewModel {
    struct ForegroundResume {
        let question: String
        let provider: AIProvider
        let model: String
    }

    struct InterruptedResume: Equatable {
        let question: String
        /// The interrupted run, whose resume command makes the resume happen once.
        let runID: String
    }

    /// Sends again, once, the question a background wind-down stopped (NH05 foreground
    /// resumption). Waits for that run to settle first; does nothing if the user has since
    /// answered, stopped, replaced or left the question, or if the stopped run had committed a
    /// document change (its tool would run again under a new invocation identity). The run
    /// starts over from the saved question with the same provider and model; nothing of the
    /// stopped run is replayed.
    func resumeAfterForeground() async {
        await waitUntilSettled()
        guard let pending = pendingForegroundResume else { return }
        pendingForegroundResume = nil
        guard retryableQuestion == pending.question, error == nil else { return }
        guard !stoppedRunCommittedEffects else {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: OperationID(), operation: "meeting_chat", stage: "background",
                outcome: .cancelled, code: "background_resume_declined"
            ))
            return
        }
        ReliabilityLog.record(ReliabilityEvent(
            operationID: OperationID(), operation: "meeting_chat", stage: "background",
            outcome: .started, code: "background_resumed"
        ))
        dropRetryableQuestion()
        send(question: pending.question, provider: pending.provider, model: pending.model)
    }

    /// Sends again, once, the question a dead process left interrupted, with the provider and model
    /// the chat would use now. The command is the interrupted run's durable resume command, so a
    /// second attempt — in this process or after another launch — runs nothing. Does nothing once
    /// the question was answered, replaced or left, or a run is already going.
    func resumeInterruptedRun(provider: AIProvider, model: String) {
        guard let pending = interruptedResume else { return }
        interruptedResume = nil
        guard !isResponding, retryableQuestion == pending.question, error == nil else { return }
        ReliabilityLog.record(ReliabilityEvent(
            operationID: OperationID(String(pending.runID.prefix(8))), operation: "meeting_chat",
            stage: "launch_recovery", outcome: .started, code: "interrupted_resumed"
        ))
        dropRetryableQuestion()
        send(question: pending.question, provider: provider, model: model,
             commandID: ChatRunBranch.resumeCommand(for: pending.runID))
    }
}

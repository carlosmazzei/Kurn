import AgentHarness
import Foundation

/// What a conversation's run is doing, as the chat shows it. `cancelling` lasts until the run
/// has settled — the producer has terminated and its required writes have finished — so the
/// UI never reports a stop that is still in progress (`CLAUDE.md`, "Agent harness").
enum ChatRunPhase: String, Sendable, Equatable {
    case idle, preparing, streaming, executingTools, compacting, retryWaiting, cancelling

    var isBusy: Bool { self != .idle }

    /// The phase a run's `AgentRunProgress` projects. Idle and cancelling are owner states that no
    /// progress can leave: only the owner settling a run returns it to idle. A finished
    /// projection keeps the current phase until the owner settles.
    func following(_ progress: AgentRunProgress) -> ChatRunPhase {
        guard self != .idle, self != .cancelling else { return self }
        switch progress.phase {
        case .preparing: return .preparing
        case .streaming: return .streaming
        case .executingTools: return .executingTools
        case .compacting: return .compacting
        case .retryWaiting: return .retryWaiting
        case .finished: return self
        }
    }
}

extension ChatRunPhase {
    /// What the running row says (NH08): the work in progress, a retry's wait with its delay when
    /// known, and a stop that is still settling. In words, never only an indicator.
    func statusText(retryDelaySeconds: Double?) -> String {
        switch self {
        case .cancelling: return NSLocalizedString("chat.step.cancelling", comment: "Stopping a reply")
        case .compacting: return NSLocalizedString("chat.step.compacting", comment: "Condensing the conversation")
        case .retryWaiting:
            guard let retryDelaySeconds, retryDelaySeconds > 0 else {
                return NSLocalizedString("chat.step.retrying", comment: "Retrying the request")
            }
            return String(format: NSLocalizedString("chat.step.retrying_in", comment: "Retrying in N seconds"),
                          Int(retryDelaySeconds.rounded(.up)))
        case .idle, .preparing, .streaming, .executingTools:
            return NSLocalizedString("chat.step.running", comment: "Running")
        }
    }
}

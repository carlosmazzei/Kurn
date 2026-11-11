import AgentHarness
import Foundation

/// What a conversation's run is doing, as the chat shows it. `cancelling` lasts until the run
/// has settled — the producer has terminated and its required writes have finished — so the
/// UI never reports a stop that is still in progress (`CLAUDE.md`, "Agent harness").
enum ChatRunPhase: String, Sendable, Equatable {
    case idle, preparing, streaming, executingTools, cancelling

    var isBusy: Bool { self != .idle }

    /// The phase after observing `event`. Idle and cancelling are owner states that no event
    /// can leave: only the owner settling a run returns it to idle.
    func applying(_ event: AgentEvent) -> ChatRunPhase {
        guard self != .idle, self != .cancelling else { return self }
        switch event {
        case .toolStarted, .toolProgress, .invocationRegistered: return .executingTools
        case .requestStarted, .turnStarted, .textDelta, .modelContent: return .streaming
        default: return self
        }
    }
}

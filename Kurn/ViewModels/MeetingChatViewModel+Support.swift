import AgentHarness
import Foundation
import KurnCore

/// Stateless helpers of `MeetingChatViewModel`, kept apart from its run and persistence state.
extension MeetingChatViewModel {
    /// The context in use against the model's window, once a response reported it.
    var contextGauge: ChatContextGauge? { ChatContextGauge(usedTokens: lastContextTokens, steps: turns.map(\.steps)) }

    /// Prior turns as plain user/assistant text: the history for a question no recorded run can
    /// replay canonically (`ChatReplayHistory`).
    static func buildHistory(from prior: [Turn]) -> [ChatMessage] {
        prior.map { ChatMessage(role: $0.role, content: $0.text) }
    }

    /// The error a failed run shows. A run whose history could not be saved says so, rather than
    /// showing the store's own error text.
    static func presentedError(_ error: Error) -> AppError {
        if ChatRunBranch.isWriteFailure(error) {
            return .apiError(statusCode: 0, message: NSLocalizedString("chat.storage.run_failed", comment: "Chat run history save error"))
        }
        if (error as? AgentSessionOwnerError) == .duplicateCommand {
            return .apiError(statusCode: 0, message: NSLocalizedString("chat.command.duplicate", comment: "Chat command already run"))
        }
        if error is AgentContextReductionError {
            return .apiError(statusCode: 0, message: NSLocalizedString("chat.context.reduction_failed",
                                                                       comment: "Chat context could not be reduced"))
        }
        return error as? AppError ?? .apiError(statusCode: 0, message: error.localizedDescription)
    }
}

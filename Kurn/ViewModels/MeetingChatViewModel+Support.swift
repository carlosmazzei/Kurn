import AgentHarness
import Foundation
import KurnCore

/// Stateless helpers of `MeetingChatViewModel`, kept apart from its run and persistence state.
extension MeetingChatViewModel {
    /// Prior turns as plain user/assistant history; old tool payloads are never replayed.
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
        return error as? AppError ?? .apiError(statusCode: 0, message: error.localizedDescription)
    }
}

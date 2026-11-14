import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Document changes the person controls: a destructive call waits for their yes, and the latest
/// change to a document can be undone from its card.
@MainActor
extension MeetingChatViewModel {
    /// Asks the person about a destructive tool call of the current run; a no ends the run
    /// (`AgentRunStopReason.terminated`), a stop of the run counts as a no.
    func confirmChange(_ call: AgentToolCall) async -> Bool {
        await changeConfirmation.request(ChatChangeRequest(call, documents: artifacts))
    }

    /// Whether `artifact`'s latest change can be undone now: a saved conversation, no reply
    /// running, and an earlier version to go back to.
    func canUndo(_ artifact: ChatDocumentArtifact) -> Bool {
        !isResponding && artifactSession != nil && artifact.version > 1
    }

    /// The card's undo action for `artifact`, nil while it cannot be undone.
    func undoAction(_ artifact: ChatDocumentArtifact) -> (() -> Void)? {
        canUndo(artifact) ? { [weak self] in self?.undoLastChange(of: artifact) } : nil
    }

    /// Gives `artifact` back the version it had before its latest change, as a new version, in
    /// one save. A failure changes nothing and is shown.
    func undoLastChange(of artifact: ChatDocumentArtifact) {
        guard canUndo(artifact), let session = artifactSession, let context = storeContext else { return }
        do {
            let documents = try SwiftDataAgentSessionStore(context: context)
                .undoLastChange(of: artifact.id, in: session, expectedRevision: session.canonicalRevision)
            try adoptDocuments(documents)
        } catch AgentSessionStoreError.notFound {
            self.error = .persistenceFailed(NSLocalizedString("chat.artifact.undo.unavailable", comment: "No earlier version"))
        } catch {
            self.error = (error as? AppError) ?? .persistenceFailed(error.localizedDescription)
        }
    }
}

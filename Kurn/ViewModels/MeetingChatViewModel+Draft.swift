import Foundation
import KurnCore

/// The composer's unsent text (A68). It lives on the view model, which the conversation host keeps
/// across dismissals, and is saved with a saved conversation when the app goes to the background,
/// when another conversation opens and before the host lets the view model go — never on every
/// keystroke, so typing never competes with a running reply's writes. A new, unsaved conversation
/// keeps it in memory only: nothing is written for a conversation that does not exist yet.
extension MeetingChatViewModel {
    /// Saves the draft with the open conversation when it changed since it was last saved. Returns
    /// false only when a save was needed and failed: the caller keeps the text on screen then.
    @discardableResult
    func saveDraft() -> Bool {
        guard let session = artifactSession, let context = session.modelContext, draft != savedDraft else { return true }
        do {
            try ChatDraftRecord.save(draft, in: session, store: SwiftDataAgentSessionStore(context: context))
            savedDraft = draft
            return true
        } catch {
            AppLog.generation.atError.error("chat: draft save failed code=\(error.publicLogCode, privacy: .public)")
            return false
        }
    }

    static var draftSaveError: AppError {
        .apiError(statusCode: 0, message: NSLocalizedString("chat.draft.save_failed", comment: "Unsent text could not be saved"))
    }

    /// Puts the conversation's saved draft back in the composer, after `carried` when there is both
    /// (text typed elsewhere or not saved is never dropped).
    func restoreDraft(of session: ChatSession, carrying carried: String = "") {
        let saved = session.modelContext.map {
            ChatDraftRecord.load(from: session, store: SwiftDataAgentSessionStore(context: $0))
        } ?? ""
        draft = [carried, saved].filter { !$0.isEmpty }.joined(separator: "\n\n")
        savedDraft = saved
    }

    /// Whether letting this view model go would lose text: a draft that is not saved anywhere.
    var holdsUnsavedDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (artifactSession == nil || draft != savedDraft)
    }
}

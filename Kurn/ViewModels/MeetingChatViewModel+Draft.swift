import Foundation
import KurnCore

/// The composer's unsent text (A68). It lives on the view model, which the conversation host keeps
/// across dismissals, and is saved with a saved conversation when the app goes to the background,
/// when another conversation opens and before the host lets the view model go — never on every
/// keystroke, so typing never competes with a running reply's writes. A new, unsaved conversation
/// keeps it in memory only: nothing is written for a conversation that does not exist yet.
extension MeetingChatViewModel {
    /// Saves the draft with the open conversation when it changed since it was last saved.
    func saveDraft() {
        guard let session = artifactSession, let context = session.modelContext, draft != savedDraft else { return }
        do {
            try ChatDraftRecord.save(draft, in: session, store: SwiftDataAgentSessionStore(context: context))
            savedDraft = draft
        } catch {
            AppLog.generation.atError.error("chat: draft save failed code=\(error.publicLogCode, privacy: .public)")
        }
    }

    /// Puts the conversation's saved draft back in the composer, or `carried` when it has none.
    func restoreDraft(of session: ChatSession, carrying carried: String = "") {
        let saved = session.modelContext.map {
            ChatDraftRecord.load(from: session, store: SwiftDataAgentSessionStore(context: $0))
        } ?? ""
        draft = saved.isEmpty ? carried : saved
        savedDraft = saved
    }

    /// Whether letting this view model go would lose text: a draft that is not saved anywhere.
    var holdsUnsavedDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (artifactSession == nil || draft != savedDraft)
    }
}

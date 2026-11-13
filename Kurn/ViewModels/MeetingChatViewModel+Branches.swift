import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// The saved conversation as a tree (NH09). Every branch is kept: a question asked again in the
/// same place is another version of it, the person moves between versions, forks a new
/// conversation from before a question (its text comes back to the composer) or duplicates the
/// conversation as it is shown. Labels and renames are metadata. Nothing changes the tree while
/// a reply runs.
extension MeetingChatViewModel {
    /// Whether the tree can change now: a saved conversation with no reply running or settling.
    var canChangeBranch: Bool { artifactSession != nil && !isResponding }

    /// Shows the version of the question `turnID` that is `offset` away, where it was left.
    func showVersion(of turnID: UUID, offset: Int) {
        guard canChangeBranch, let session = artifactSession, let context = session.modelContext,
              let entryID = branches.alternatives[turnID]?.entryID(offset: offset) else { return }
        do {
            try SwiftDataAgentSessionStore(context: context).navigate(session, to: entryID, expectedRevision: session.canonicalRevision)
            load(session: session)
        } catch {
            branchFailed()
        }
    }

    /// Opens the branch through the question `entryID` (from the tree of every branch), where it
    /// was left.
    func showBranch(at entryID: String) {
        guard canChangeBranch, let session = artifactSession, let context = session.modelContext else { return }
        do {
            try SwiftDataAgentSessionStore(context: context).navigate(session, to: entryID, expectedRevision: session.canonicalRevision)
            load(session: session)
        } catch {
            branchFailed()
        }
    }

    /// Starts a new conversation from before the question `turnID`, with that question back in
    /// the composer to change and send. This conversation is unchanged.
    func fork(from turnID: UUID) {
        guard canChangeBranch, let session = artifactSession, let context = session.modelContext,
              let entryID = branches.entryIDs[turnID], let question = turns.first(where: { $0.id == turnID })?.text else { return }
        do {
            let store = SwiftDataAgentSessionStore(context: context)
            let before = try store.tree(session).entry(entryID)?.parentID
            if let fork = try store.copy(session, through: before, title: session.title, askedAt: entryID) {
                load(session: fork)
            } else {
                reset()
            }
            restoreToDraft([question])
        } catch {
            branchFailed()
        }
    }

    /// Duplicates the conversation as it is shown, as a new conversation.
    func duplicateConversation() {
        guard canChangeBranch, let session = artifactSession, let context = session.modelContext else { return }
        do {
            let title = String(format: NSLocalizedString("chat.branch.copy_title", comment: "Duplicated conversation title"), session.title)
            if let copy = try SwiftDataAgentSessionStore(context: context).copy(session, through: session.canonicalLeafID, title: title) {
                load(session: copy)
            }
        } catch {
            branchFailed()
        }
    }

    /// Labels the turn `turnID`; an empty label removes it.
    func label(turnID: UUID, as label: String) {
        guard canChangeBranch, let session = artifactSession, let context = session.modelContext,
              let entryID = branches.entryIDs[turnID] else { return }
        do {
            try SwiftDataAgentSessionStore(context: context).label(session, entry: entryID, as: label)
            refreshBranches()
        } catch {
            branchFailed()
        }
    }

    /// Leaves the exchange that starts with the question `turnID` out of what later answers read,
    /// or includes it again. The conversation shown and its usage are unchanged.
    func setLeftOut(_ leftOut: Bool, question turnID: UUID) {
        guard canChangeBranch, let session = artifactSession, let context = session.modelContext,
              let index = turns.firstIndex(where: { $0.id == turnID && $0.role == .user }) else { return }
        var ids = [turnID]
        if turns.indices.contains(index + 1), turns[index + 1].role == .assistant { ids.append(turns[index + 1].id) }
        do {
            let store = SwiftDataAgentSessionStore(context: context)
            if leftOut { try store.editContext(session, leavingOut: ids) } else { try store.editContext(session, including: ids) }
            refreshBranches()
        } catch {
            branchFailed()
        }
    }

    /// Renames a saved conversation in this chat's history.
    func rename(_ target: ChatSession, to title: String) {
        guard let context = target.modelContext else { return }
        do { try SwiftDataAgentSessionStore(context: context).rename(target, to: title) } catch { branchFailed() }
    }

    func refreshBranches() {
        guard let session = artifactSession, let context = session.modelContext,
              let tree = try? SwiftDataAgentSessionStore(context: context).tree(session) else {
            branches = ChatBranchPresentation()
            return
        }
        branches = ChatBranchPresentation(tree: tree)
    }

    private func branchFailed() {
        error = .apiError(statusCode: 0, message: NSLocalizedString("chat.branch.failed", comment: "Branch change failed"))
    }
}

import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Exporting and importing saved conversations (NH10). The archive is the whole conversation —
/// every branch, for a later import; the reading export is the branch shown, as Markdown, Word or HTML. Both are
/// written to a protected temporary file the share sheet hands on, and an import always becomes
/// a new conversation in this chat, never a change to an existing one.
extension MeetingChatViewModel {
    /// The open conversation as a native archive file, or nil (with the error shown).
    func exportArchive() -> URL? {
        guard !isResponding, let session = artifactSession, let context = session.modelContext else { return nil }
        do {
            let data = try SwiftDataAgentSessionStore(context: context).archive(session)
            return try MeetingExport.temporaryFile(data: data, suggestedName: session.title, fileExtension: "jsonl")
        } catch {
            archiveFailed("chat.archive.export_failed")
            return nil
        }
    }

    /// The conversation shown as a file to read: Markdown, or a Word or HTML document rendered from
    /// it by the meeting export's renderers — the HTML is one self-contained page with every text
    /// escaped, no script, no external resource and no link.
    func exportReadable(as format: MeetingExportFormat = .standard) -> URL? {
        guard !isResponding, !turns.isEmpty else { return nil }
        let title = artifactSession?.title ?? ChatSession.title(from: turns.first { $0.role == .user }?.text ?? "")
        let markdown = ChatConversationMarkdown.render(title: title, turns: turns.map(PersistedChatTurn.init), artifacts: artifacts)
        do {
            return try DocumentExport.file(title: title, markdown: markdown, format: format)
        } catch {
            archiveFailed("chat.archive.export_failed")
            return nil
        }
    }

    /// Imports the archive at `url` as a new conversation here, and opens it.
    func importConversation(from url: URL) {
        guard !isResponding, let context = storeContext else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= AgentSessionArchive.Limits().maximumTotalBytes else { throw AgentSessionArchiveError.tooLarge }
            let data = try Data(contentsOf: url)
            let imported = try SwiftDataAgentSessionStore(context: context).importArchive(data, meeting: scopeMeeting,
                defaultTitle: NSLocalizedString("chat.archive.imported_title", comment: "Title of an imported conversation"))
            load(session: imported)
        } catch {
            archiveFailed("chat.archive.import_failed")
        }
    }

    private func archiveFailed(_ key: String) {
        error = .apiError(statusCode: 0, message: NSLocalizedString(key, comment: "Conversation archive failure"))
    }
}

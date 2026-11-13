import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Archival export and import of a saved conversation (NH10), as an `AgentSessionArchive`: the
/// whole log with every branch, plus the document revisions it shows (`kurn.artifact-revision`,
/// their exact stored bytes) and the conversation's title (`kurn.conversation`). Run records,
/// queued input and document receipts stay behind: an archive carries no live or pending
/// operation, and no credentials ever reach the log.
@MainActor
extension SwiftDataAgentSessionStore {
    static let conversationRecord = "kurn.conversation"
    static let revisionRecord = "kurn.artifact-revision"

    /// How an import treats the archive's session identity: a new copy always takes a new one; a
    /// restore keeps it, and is refused when a conversation already has it.
    enum ArchiveImport { case newCopy, restore }

    /// The conversation as a native archive.
    func archive(_ target: ChatSession) throws -> Data {
        let snapshot = try snapshot(target)
        var records = [AgentSessionArchive.Record(type: Self.conversationRecord, data: .object([
            "title": .string(target.title), "createdAt": .string(AgentSessionEntry.time(target.createdAt))]))]
        for row in target.harnessRevisions.sorted(by: { $0.id < $1.id }) {
            _ = try Self.checkedRevision(row, session: target)
            records.append(.init(type: Self.revisionRecord, data: .object([
                "id": .string(row.id), "payload": .string(row.payloadData.base64EncodedString())])))
        }
        return try AgentSessionArchive(sessionID: snapshot.sessionID, leafID: snapshot.leafID, entries: snapshot.entries,
                                       records: records).jsonl()
    }

    /// A new saved conversation in `meeting`'s chat (nil for the library) from an archive. Nothing
    /// is written unless the whole archive holds: its graph, every document revision it carries
    /// (checked against its own bytes), every revision a branch shows, and the branch it selects.
    func importArchive(_ data: Data, meeting: Meeting?, as mode: ArchiveImport = .newCopy,
                       defaultTitle: String) throws -> ChatSession {
        let archive = try AgentSessionArchive.decode(data)
        guard archive.leafID != nil else { throw AgentSessionStoreError.invalidGraph }
        let conversation = archive.records.last { $0.type == Self.conversationRecord }
        let title: String
        if case .object(let fields)? = conversation?.data, case .string(let saved)? = fields["title"],
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = String(saved.prefix(120))
        } else {
            title = defaultTitle
        }
        let target = ChatSession(meeting: meeting, title: title)
        if mode == .restore {
            guard let id = UUID(uuidString: archive.sessionID), (try? session(archive.sessionID)) == nil else {
                throw AgentSessionStoreError.conflict
            }
            target.id = id
        }
        let newID = target.id.uuidString
        let moved = newID == archive.sessionID ? archive : try archive.copy(into: newID)
        // Every branch must open, not only the selected one: each conversation message and each
        // saved state is read here (a state that does not decode fails `rebased`), before anything is
        // written.
        let entries = try moved.entries.map { try Self.rebased($0, from: archive.sessionID, to: newID) }
        for entry in entries where entry.runID == nil {
            if case .message = entry.payload { _ = try HarnessPresentationCodec.turn(entry) }
        }
        let revisions = try archive.records.filter { $0.type == Self.revisionRecord }.map { record -> HarnessArtifactRevision in
            guard case .object(let fields) = record.data, case .string(let id)? = fields["id"],
                  case .string(let encoded)? = fields["payload"], let payload = Data(base64Encoded: encoded) else {
                throw AgentSessionStoreError.corruptPayload
            }
            // Each revision is checked against its own bytes before anything is written.
            let artifact = try HarnessPresentationCodec.decode(ChatDocumentArtifact.self, from: payload)
            let revisionID = Self.rebased(id, from: archive.sessionID, to: newID)
            guard artifact.version > 0, Self.isRevisionID(revisionID, session: target, artifact: artifact, payload: payload) else {
                throw AgentSessionStoreError.corruptPayload
            }
            _ = try ChatDocumentWorkspace(artifacts: [artifact])
            return HarnessArtifactRevision(session: target, artifactID: artifact.id, version: artifact.version, payloadData: payload,
                                           id: revisionID)
        }
        guard Set(revisions.map(\.id)).count == revisions.count,
              Set(entries.flatMap(Self.revisionIDs)).isSubset(of: revisions.map(\.id)) else { throw AgentSessionStoreError.corruptPayload }
        context.insert(target)
        do {
            for entry in entries {
                insert(HarnessSessionEntry(session: target, entryID: entry.id, parentEntryID: entry.parentID, ordinal: entry.ordinal,
                    kindRaw: entry.kind, createdAtUTC: entry.createdAt, payloadData: try HarnessPresentationCodec.encode(entry)), into: target)
            }
            for row in revisions {
                row.session = target
                context.insert(row)
                _ = try Self.checkedRevision(row, session: target)
            }
            target.canonicalVersion = 1; target.canonicalLeafID = moved.leafID
            target.canonicalOrdinal = entries.count; target.canonicalRevision = 1
            let projection = try Self.projection(target)
            let cache = try PresentationCache(turns: projection.turns, scope: projection.scope, artifacts: projection.artifacts)
            target.turnsData = cache.turns; target.scopeData = cache.scope; target.artifactsData = cache.artifacts
            _ = try snapshot(target)
            try save(context)
            return target
        } catch {
            context.delete(target)
            throw error
        }
    }
}

/// The conversation shown, as Markdown to read (NH10): the selected branch's questions and
/// answers and the documents it shows, with their text, never other branches or the archive's
/// internals. It is
/// text for a reader, not an archive, and carries no HTML of its own.
enum ChatConversationMarkdown {
    static func render(title: String, turns: [PersistedChatTurn], artifacts: [ChatDocumentArtifact]) -> String {
        var lines = ["# " + title, ""]
        for turn in turns where !turn.text.isEmpty {
            let speaker = turn.role == .user
                ? NSLocalizedString("chat.export.you", comment: "Questions in an exported conversation")
                : NSLocalizedString("chat.export.assistant", comment: "Answers in an exported conversation")
            lines += ["**" + speaker + "**", "", turn.text, ""]
        }
        if !artifacts.isEmpty {
            lines += ["---", "", "## " + NSLocalizedString("chat.export.documents", comment: "Documents in an exported conversation"), ""]
            for artifact in artifacts {
                lines += ["### " + artifact.title + " (v" + String(artifact.version) + ")", "", artifact.markdown, ""]
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

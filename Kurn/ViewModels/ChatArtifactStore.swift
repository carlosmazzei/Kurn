import Foundation
import KurnCore
import SwiftData

@MainActor
struct ChatArtifactStore {
    enum ArtifactSaveAction: String {
        case save = "chat.artifact.save"
        case update = "chat.artifact.update"
        case saved = "chat.artifact.saved"
    }

    let context: ModelContext
    var saveChanges: @MainActor (ModelContext) -> AppError? = { $0.saveOrError() }

    /// Revision-aware (NH09): the saved document is this revision only when it holds the same
    /// version with the same body. Another branch's revision — an older version, or the same
    /// version with other content — offers to replace it, like a newer one does.
    static func action(artifact: ChatDocumentArtifact, saved: GeneratedDocument?) -> ArtifactSaveAction {
        guard let saved else { return .save }
        return saved.sourceArtifactVersion == artifact.version && saved.bodyMarkdown == artifact.markdown ? .saved : .update
    }

    func savedDocument(artifactID: UUID, sessionID: UUID) throws -> GeneratedDocument? {
        let descriptor = FetchDescriptor<GeneratedDocument>(predicate: #Predicate {
            $0.sourceChatSessionID == sessionID && $0.sourceArtifactID == artifactID
        })
        return try context.fetch(descriptor).first
    }

    func save(artifactID: UUID, session: ChatSession) throws -> GeneratedDocument? {
        let snapshot = try session.harnessSnapshot()
        guard let artifact = snapshot.artifacts.first(where: { $0.id == artifactID }) else { return nil }
        let existing = try savedDocument(artifactID: artifactID, sessionID: session.id)
        if Self.action(artifact: artifact, saved: existing) == .saved { return existing }
        let scope = snapshot.scope ?? ChatSourceScope(kind: .meetings, selectedIDs: Set([session.meeting?.id].compactMap { $0 }))
        let origin = Self.origin(artifactID: artifactID, in: snapshot.turns)
        let previousSources = existing.map { ChatArtifactSources(kind: $0.sourceKind, meetingIDs: $0.sourceMeetingIDs, names: $0.sourceNames) }
        let sources = try (origin.sources ?? ChatArtifactSources.capture(scope: scope, context: context)).retaining(previousSources)
        return try MeetingLibrary(context: context, persist: saveChanges).saveDocument(
            artifact: artifact, origin: origin, sources: sources, sessionID: session.id, updating: existing)
    }

    static func origin(artifactID: UUID, in turns: [PersistedChatTurn]) -> ChatArtifactOrigin {
        ChatArtifactOrigin.recorded(artifactID: artifactID, in: turns)
    }

}

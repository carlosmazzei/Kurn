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

    static func action(artifact: ChatDocumentArtifact, saved: GeneratedDocument?) -> ArtifactSaveAction {
        guard let saved else { return .save }
        return artifact.version > (saved.sourceArtifactVersion ?? 0) ? .update : .saved
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
        var question = ""
        var result = ChatArtifactOrigin(question: "", modelIdentifier: "")
        for turn in turns {
            if turn.role == .user { question = turn.text }
            if let origin = turn.artifactOrigins?[artifactID] { result = origin }
            else if turn.artifacts?.contains(where: { $0.id == artifactID }) == true {
                result = ChatArtifactOrigin(question: question, modelIdentifier: "")
            }
        }
        return result
    }

}

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
    var saveChanges: (ModelContext) -> AppError? = { $0.saveOrError() }

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
        let origin = Self.origin(artifactID: artifactID, in: session.turns)
        let previousSources = existing.map { ChatArtifactSources(kind: $0.sourceKind, meetingIDs: $0.sourceMeetingIDs, names: $0.sourceNames) }
        let sources = try (origin.sources ?? ChatArtifactSources.capture(scope: scope, context: context)).retaining(previousSources)
        let document = existing ?? GeneratedDocument(title: artifact.title, bodyMarkdown: artifact.markdown,
            userPrompt: origin.question, sourceKind: sources.kind, sourceNames: sources.names,
            sourceMeetingIDs: sources.meetingIDs, generatorModelIdentifier: origin.modelIdentifier)
        let previous = existing.map { DocumentSnapshot($0) }
        document.title = artifact.title
        document.bodyMarkdown = artifact.markdown
        document.userPrompt = origin.question
        document.generatorModelIdentifier = origin.modelIdentifier
        document.sourceKind = sources.kind
        document.sourceNames = sources.names
        document.sourceMeetingIDs = sources.meetingIDs
        document.sourceChatSessionID = session.id
        document.sourceArtifactID = artifact.id
        document.sourceArtifactVersion = artifact.version
        if existing == nil { context.insert(document) }
        if let error = saveChanges(context) {
            if let previous { previous.restore(document) } else { context.delete(document) }
            throw error
        }
        return document
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

    private struct DocumentSnapshot {
        let title: String, body: String, prompt: String, model: String, kind: String
        let names: Data, ids: Data
        let sessionID: UUID?, artifactID: UUID?, version: Int?

        init(_ document: GeneratedDocument) {
            title = document.title
            body = document.bodyMarkdown
            prompt = document.userPrompt
            model = document.generatorModelIdentifier
            kind = document.sourceKindRaw
            names = document.sourceNamesData
            ids = document.sourceMeetingIDsData
            sessionID = document.sourceChatSessionID
            artifactID = document.sourceArtifactID
            version = document.sourceArtifactVersion
        }

        func restore(_ document: GeneratedDocument) {
            document.title = title
            document.bodyMarkdown = body
            document.userPrompt = prompt
            document.generatorModelIdentifier = model
            document.sourceKindRaw = kind
            document.sourceNamesData = names
            document.sourceMeetingIDsData = ids
            document.sourceChatSessionID = sessionID
            document.sourceArtifactID = artifactID
            document.sourceArtifactVersion = version
        }
    }
}

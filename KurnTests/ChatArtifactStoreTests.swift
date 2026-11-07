import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatArtifactStoreTests {
    private func session(context: ModelContext, artifact: ChatDocumentArtifact) -> ChatSession {
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let session = ChatSession(meeting: nil, title: "Documents")
        session.scopeData = JSONStorage.encodeAuthoritative(ChatSourceScope(kind: .meetings, selectedIDs: [meeting.id]))
        session.artifactsData = JSONStorage.encodeAuthoritative([artifact])
        var user = MeetingChatViewModel.Turn(role: .user, text: "Write minutes")
        user.artifacts = [ChatArtifactReference(artifact)]
        user.artifactOrigins = [artifact.id: ChatArtifactOrigin(question: "Write minutes", modelIdentifier: "openai:gpt-4o")]
        session.turns = [PersistedChatTurn(user)]
        context.insert(session)
        return session
    }

    @Test func saveUpdateDeletedResaveAndProvenance() throws {
        let context = ModelContext(TestModelContainer.make())
        let artifact = ChatDocumentArtifact(id: UUID(), title: "Minutes", markdown: "# Minutes\n\nBody", version: 1)
        let session = session(context: context, artifact: artifact)
        let store = ChatArtifactStore(context: context)
        #expect(ChatArtifactStore.action(artifact: artifact, saved: nil) == .save)
        let document = try #require(store.save(artifactID: artifact.id, session: session))
        let originalID = document.id
        let createdAt = document.createdAt
        #expect(document.sourceChatSessionID == session.id)
        #expect(document.sourceArtifactID == artifact.id)
        #expect(document.sourceArtifactVersion == 1)
        #expect(document.sourceNames == ["Planning"])
        #expect(document.sourceMeetingIDs.count == 1)
        #expect(document.title == artifact.title)
        #expect(document.bodyMarkdown == artifact.markdown)
        #expect(document.userPrompt == "Write minutes")
        #expect(document.generatorModelIdentifier == "openai:gpt-4o")
        #expect(ChatArtifactStore.action(artifact: artifact, saved: document) == .saved)
        #expect(try store.save(artifactID: artifact.id, session: session)?.id == originalID)
        let revised = ChatDocumentArtifact(id: artifact.id, title: "New title", markdown: "Revised", version: 2)
        session.artifactsData = JSONStorage.encodeAuthoritative([revised])
        var revision = MeetingChatViewModel.Turn(role: .assistant, text: "Revised the document")
        revision.artifacts = [ChatArtifactReference(revised)]
        revision.artifactOrigins = [artifact.id: ChatArtifactOrigin(question: "Revise it", modelIdentifier: "anthropic:claude")]
        session.turns += [PersistedChatTurn(revision)]
        #expect(ChatArtifactStore.action(artifact: revised, saved: document) == .update)
        #expect(try store.save(artifactID: artifact.id, session: session)?.id == originalID)
        #expect(document.title == "New title")
        #expect(document.bodyMarkdown == "Revised")
        #expect(document.sourceArtifactVersion == 2)
        #expect(document.createdAt == createdAt)
        #expect(document.userPrompt == "Revise it")
        #expect(document.generatorModelIdentifier == "anthropic:claude")
        #expect(try context.fetch(FetchDescriptor<GeneratedDocument>()).count == 1)
        context.delete(document)
        try context.save()
        #expect(try store.savedDocument(artifactID: artifact.id, sessionID: session.id) == nil)
        let replacement = try #require(store.save(artifactID: artifact.id, session: session))
        #expect(replacement.id != originalID)
        #expect(replacement.sourceArtifactVersion == 2)
    }

    @Test func plainRepliesUnknownArtifactsAndCorruptStorageCannotBeSaved() throws {
        let context = ModelContext(TestModelContainer.make())
        let session = ChatSession(meeting: nil, title: "Plain reply")
        let turn = MeetingChatViewModel.Turn(role: .assistant, text: "# This is not an artifact")
        session.turns = [PersistedChatTurn(turn)]
        context.insert(session)
        let store = ChatArtifactStore(context: context)
        #expect(try store.save(artifactID: turn.id, session: session) == nil)
        #expect(try context.fetch(FetchDescriptor<GeneratedDocument>()).isEmpty)
        session.artifactsData = Data("broken".utf8)
        #expect(throws: AppError.self) { try store.save(artifactID: UUID(), session: session) }
    }

    @Test func failedSaveRestoresExistingDocumentAndRemovesNewInsertion() throws {
        let context = ModelContext(TestModelContainer.make())
        let artifact = ChatDocumentArtifact(id: UUID(), title: "Minutes", markdown: "Body", version: 1)
        let session = session(context: context, artifact: artifact)
        let failing = ChatArtifactStore(context: context, saveChanges: { _ in .persistenceFailed("Test failure") })
        #expect(throws: AppError.self) { try failing.save(artifactID: artifact.id, session: session) }
        try context.save()
        #expect(try context.fetch(FetchDescriptor<GeneratedDocument>()).isEmpty)
        let document = try #require(ChatArtifactStore(context: context).save(artifactID: artifact.id, session: session))
        let revised = ChatDocumentArtifact(id: artifact.id, title: "Revised", markdown: "Changed", version: 2)
        session.artifactsData = JSONStorage.encodeAuthoritative([revised])
        #expect(throws: AppError.self) { try failing.save(artifactID: artifact.id, session: session) }
        #expect(document.title == "Minutes")
        #expect(document.bodyMarkdown == "Body")
        #expect(document.sourceArtifactVersion == 1)
        #expect(document.sourceChatSessionID == session.id)
    }

    @Test func olderSessionsInferQuestionAndSourceKindsWithoutInventingModel() throws {
        let context = ModelContext(TestModelContainer.make())
        let artifact = ChatDocumentArtifact(id: UUID(), title: "Report", markdown: "Body", version: 1)
        let session = session(context: context, artifact: artifact)
        var turn = try #require(session.turns.first)
        turn.artifactOrigins = nil
        session.turns = [turn]
        for kind in [ChatSourceScope.Kind.tags, .folders, .library] {
            session.scopeData = JSONStorage.encodeAuthoritative(ChatSourceScope(kind: kind))
            let document = try #require(ChatArtifactStore(context: context).save(artifactID: artifact.id, session: session))
            #expect(document.userPrompt == "Write minutes")
            #expect(document.generatorModelIdentifier.isEmpty)
            #expect(document.sourceKind == (kind == .tags ? .tags : kind == .folders ? .folders : .transcripts))
            context.delete(document)
            try context.save()
        }
        session.scopeData = nil
        #expect(try ChatArtifactStore(context: context).save(artifactID: artifact.id, session: session) != nil)
    }
}

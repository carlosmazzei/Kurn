import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatArtifactSourcesTests {
    @Test func sourceSnapshotSurvivesScopeChangesDeletionAndRevision() throws {
        let context = ModelContext(TestModelContainer.make())
        let first = MeetingFixtures.transcribed("Original", in: context)
        let second = MeetingFixtures.transcribed("Other", in: context)
        let sources = try ChatArtifactSources.capture(scope: ChatSourceScope(kind: .meetings, selectedIDs: [first.id]), context: context)
        let firstID = first.id
        let artifact = ChatDocumentArtifact(title: "Report", markdown: "Body")
        let session = ChatSession(meeting: nil, title: "Chat")
        context.insert(session)
        session.scopeData = JSONStorage.encodeAuthoritative(ChatSourceScope(kind: .meetings, selectedIDs: [second.id]))
        session.artifactsData = JSONStorage.encodeAuthoritative([artifact])
        var turn = MeetingChatViewModel.Turn(role: .user, text: "Write report")
        turn.artifacts = [ChatArtifactReference(artifact)]
        turn.artifactOrigins = [artifact.id: ChatArtifactOrigin(question: turn.text, modelIdentifier: "model", sources: sources)]
        session.turns = [PersistedChatTurn(turn)]
        context.delete(first)
        try context.save()
        let store = ChatArtifactStore(context: context)
        let document = try #require(store.save(artifactID: artifact.id, session: session))
        #expect(document.sourceMeetingIDs == [firstID])
        #expect(document.sourceNames == ["Original"])
        let revised = ChatDocumentArtifact(id: artifact.id, title: artifact.title, markdown: "Revision", version: 2)
        let current = try ChatArtifactSources.capture(scope: ChatSourceScope(kind: .meetings, selectedIDs: [second.id]), context: context)
        var revision = MeetingChatViewModel.Turn(role: .assistant, text: "Revised")
        revision.recordArtifacts(from: [artifact], to: [revised],
            origin: ChatArtifactOrigin(question: "Revise", modelIdentifier: "model", sources: current), priorOrigins: turn.artifactOrigins)
        session.turns += [PersistedChatTurn(revision)]
        session.artifactsData = JSONStorage.encodeAuthoritative([revised])
        _ = try store.save(artifactID: artifact.id, session: session)
        #expect(document.sourceMeetingIDs == [firstID, second.id])
        #expect(document.sourceNames == ["Original", "Other"])
        #expect(try session.harnessSnapshot().artifacts.first?.version == 2)
        #expect(session.turns.last?.artifactOrigins?[artifact.id]?.sources?.names == ["Original", "Other"])
    }

    @Test func sourceSnapshotsRetainRetaggedMeetingsAndSupportEmptyAndLegacyOrigins() throws {
        let context = ModelContext(TestModelContainer.make())
        let tag = Tag(name: "Project")
        context.insert(tag)
        let meeting = MeetingFixtures.transcribed("Meeting", in: context)
        meeting.tags = [tag]
        let scope = ChatSourceScope(kind: .tags, selectedIDs: [tag.id])
        let original = try ChatArtifactSources.capture(scope: scope, context: context)
        meeting.tags = []
        let empty = try ChatArtifactSources.capture(scope: scope, context: context)
        #expect(empty.meetingIDs.isEmpty)
        #expect(empty.retaining(original).meetingIDs == [meeting.id])
        #expect(empty.retaining(original).names == ["Project"])
        #expect(original.retaining(original) == original)
        #expect(empty.retaining(nil) == empty)
        let legacy = try JSONDecoder().decode(ChatArtifactOrigin.self, from: Data(#"{"question":"Q","modelIdentifier":"M"}"#.utf8))
        #expect(legacy.sources == nil)
    }
}

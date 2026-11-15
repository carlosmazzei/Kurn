import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

private final class NH01FixtureBundle: NSObject {}

private struct LegacySessionFixture: Decodable {
    let fixtureVersion: Int
    let baselineCommit: String
    let turns: [PersistedChatTurn]
    let scope: ChatSourceScope
    let artifacts: [ChatDocumentArtifact]
    let meetingID: UUID
    let excludedMeetingID: UUID

    static func data() throws -> Data {
        let bundle = Bundle(for: NH01FixtureBundle.self)
        let url = try #require(bundle.url(forResource: "nh01-session-v1", withExtension: "json")
            ?? bundle.url(forResource: "nh01-session-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func load() throws -> Self {
        let fixture = try JSONDecoder().decode(Self.self, from: data())
        #expect(fixture.fixtureVersion == 1)
        #expect(fixture.baselineCommit == "6ec656b93c6cf59cbc3dc32f9bd08e1abb1517ed")
        return fixture
    }

    func rawPayload(_ field: String) throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: Self.data()) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: #require(object[field]))
    }

    @MainActor func restore(in context: ModelContext) throws -> ChatSession {
        let selected = MeetingFixtures.transcribed("Selected fixture source", in: context)
        selected.id = meetingID
        let excluded = MeetingFixtures.transcribed("Excluded fixture source", in: context)
        excluded.id = excludedMeetingID
        let session = ChatSession(meeting: nil, title: "Legacy fixture")
        // Feed pre-envelope bytes to the actual app readers, including ignored retrieval citations.
        session.turnsData = try rawPayload("turns")
        session.scopeData = try rawPayload("scope")
        session.artifactsData = try rawPayload("artifacts")
        context.insert(session)
        try context.save()
        return session
    }
}

@MainActor
struct NativeHarnessContractFixtureTests {
    @Test func legacySessionRestoresScopeTraceArtifactsAndRetryIdentity() throws {
        let fixture = try LegacySessionFixture.load()
        let context = ModelContext(TestModelContainer.make())
        let session = try fixture.restore(in: context)
        let vm = MeetingChatViewModel()
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: session)
        #expect(vm.error == nil)
        #expect(vm.turns.map(\.id) == fixture.turns.map(\.id))
        #expect(vm.scope == fixture.scope)
        #expect(vm.scope.parts(for: fixture.excludedMeetingID).isEmpty)
        #expect(vm.artifacts == fixture.artifacts)
        #expect(vm.turns[1].steps == fixture.turns[1].steps)
        #expect(vm.turns[1].usage == TokenUsage(promptTokens: 123, completionTokens: 45))
        #expect(vm.turns[1].costUSD == 0.002)
        #expect(vm.turns[1].artifacts.first?.version == 3)
        #expect(vm.retryableQuestion == "Gerar documento")
        #expect(vm.turns.last?.steps.last?.stopReason == .outputLimit)
        let rewritten = try JSONDecoder().decode([PersistedChatTurn].self, from: JSONEncoder().encode(session.turns))
        #expect(rewritten.map(\.id) == fixture.turns.map(\.id))
        #expect(rewritten[1].steps == fixture.turns[1].steps)
    }

    @Test func legacyArtifactsCanBeSavedAndUpdatedAsOneLibraryDocument() throws {
        let fixture = try LegacySessionFixture.load()
        let context = ModelContext(TestModelContainer.make())
        let session = try fixture.restore(in: context)
        let artifact = try #require(fixture.artifacts.first)
        let store = ChatArtifactStore(context: context)
        let saved = try #require(try store.save(artifactID: artifact.id, session: session))
        let savedID = saved.id
        #expect(saved.sourceChatSessionID == session.id)
        #expect(saved.sourceArtifactID == artifact.id)
        #expect(saved.sourceArtifactVersion == 3)
        #expect(saved.bodyMarkdown == artifact.markdown)
        #expect(saved.userPrompt == "Pergunta anterior")
        #expect(ChatArtifactStore.origin(artifactID: artifact.id, in: session.turns).modelIdentifier.isEmpty)
        let updated = ChatDocumentArtifact(id: artifact.id, title: artifact.title, markdown: artifact.markdown + "\n\nUpdated", version: 4)
        session.artifactsData = JSONStorage.encodeAuthoritative([updated])
        #expect(try store.save(artifactID: artifact.id, session: session)?.id == savedID)
        #expect(saved.sourceArtifactVersion == 4)
        #expect(saved.bodyMarkdown == updated.markdown)
        #expect(try context.fetch(FetchDescriptor<GeneratedDocument>()).count == 1)
        #expect(session.turns[1].artifacts?.first?.version == 3)
    }

    @Test func narrowedScopeReplaysPlainHistoryWithoutLegacyCitationsToolsOrDocumentBodies() async throws {
        let fixture = try LegacySessionFixture.load()
        let context = ModelContext(TestModelContainer.make())
        let session = try fixture.restore(in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Scoped answer")])
        let service = HarnessChatService(refreshMetadata: { _, _, _ in .unsupported })
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: service)
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: session)
        vm.dropRetryableQuestion()
        vm.updateScope(ChatSourceScope(kind: .meetings, selectedIDs: [fixture.meetingID], parts: [.transcript]))
        vm.send(question: "Nova pergunta", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding && vm.error == nil)
        let request = try #require(await model.requests.first)
        #expect(request.messages.map(\.legacyProjection) == [.user("Pergunta anterior"), .assistant(text: "Resposta anterior [0:12]", toolCalls: []),
                                      .user("Nova pergunta")])
        let serialized = String(describing: request)
        #expect(!serialized.contains("EXCLUDED LEGACY CITATION"))
        #expect(!serialized.contains("Read fixture facts"))
        #expect(!serialized.contains(fixture.artifacts[0].markdown))
        #expect(vm.scope.selectedIDs == [fixture.meetingID])
    }

    @Test func corruptScopeAndArtifactPayloadsAreSurfacedAsErrors() throws {
        let fixture = try LegacySessionFixture.load()
        let context = ModelContext(TestModelContainer.make())
        let session = try fixture.restore(in: context)
        session.scopeData = Data("{broken".utf8)
        #expect(throws: AppError.self) { try session.harnessSnapshot() }
        session.scopeData = try fixture.rawPayload("scope")
        session.artifactsData = Data("{broken".utf8)
        #expect(throws: AppError.self) { try session.harnessSnapshot() }
    }
}

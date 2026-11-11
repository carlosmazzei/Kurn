import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessArtifactRetryTests {
    @Test func cancellationKeepsCreatedArtifactAndItsOrigin() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let create = try chatAgentCall("create_document", arguments: .object(["title": .string("Report"), "markdown": .string("Body")]))
        let model = ChatAgentModel([AgentTurnResponse(text: "", toolCalls: [create]), AgentTurnResponse(text: "Working")], pauseAt: 1)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "Write a report", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.artifacts.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let artifact = try #require(vm.artifacts.first)
        vm.cancel()
        await vm.waitUntilSettled()
        #expect(vm.turns.flatMap(\.artifacts) == [ChatArtifactReference(artifact)])
        let session = try #require(vm.pastSessions().first)
        #expect(ChatArtifactStore.origin(artifactID: artifact.id, in: session.turns).modelIdentifier == "\(AIProvider.openAI.id):gpt-4o")
        vm.load(session: session)
        #expect(vm.turns.flatMap(\.artifacts) == [ChatArtifactReference(artifact)])
    }

    @Test func createdDocumentRemainsVisibleAfterProviderFailure() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let create = try chatAgentCall("create_document", arguments: .object(["title": .string("Report"), "markdown": .string("Body")]))
        let model = ChatAgentModel([AgentTurnResponse(text: "", toolCalls: [create])])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "Write a report", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
        #expect(vm.error != nil)
        let artifact = try #require(vm.artifacts.first)
        #expect(vm.turns.flatMap(\.artifacts) == [ChatArtifactReference(artifact)])
        let session = try #require(vm.pastSessions().first)
        #expect(ChatArtifactStore.origin(artifactID: artifact.id, in: session.turns).question == "Write a report")
        vm.load(session: session)
        #expect(vm.turns.flatMap(\.artifacts) == [ChatArtifactReference(artifact)])
    }

    @Test(arguments: [false, true]) func createdDocumentReferencesSurviveRetryAndReopening(completes: Bool) async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let create = try chatAgentCall("create_document", arguments: .object(["title": .string("Minutes"), "markdown": .string("Body")]))
        let responses = [AgentTurnResponse(text: "", toolCalls: [create])] + (completes ? [AgentTurnResponse(text: "Done")] : [])
        let model = ChatAgentModel(responses)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model },
                                      harnessService: HarnessChatService(limits: AgentLimits(maxTurns: 1)))
        vm.configure(meeting: meeting, modelContext: context)
        func ask(_ question: String = "Write minutes") {
            vm.send(question: question, provider: .openAI, model: "gpt-4o")
        }
        func waitUntilDone() async {
            for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(!vm.isResponding)
        }
        ask()
        await waitUntilDone()
        let artifact = try #require(vm.artifacts.first)
        #expect(vm.retryableQuestion == "Write minutes")
        #expect(vm.turns.last?.artifacts == [ChatArtifactReference(artifact)])
        vm.dropRetryableQuestion()
        ask("Try again")
        await waitUntilDone()
        #expect(vm.turns.flatMap(\.artifacts) == [ChatArtifactReference(artifact)])
        #expect((vm.error == nil) == completes)
        let session = try #require(vm.pastSessions().first)
        #expect(session.turns.flatMap { $0.artifacts ?? [] } == [ChatArtifactReference(artifact)])
        #expect(ChatArtifactStore.origin(artifactID: artifact.id, in: session.turns).question == "Write minutes")
        #expect(ChatArtifactStore.origin(artifactID: artifact.id, in: session.turns).modelIdentifier == "\(AIProvider.openAI.id):gpt-4o")
        vm.load(session: session)
        #expect(vm.artifacts == [artifact])
        #expect(vm.turns.flatMap(\.artifacts) == [ChatArtifactReference(artifact)])
        vm.dropRetryableQuestion()
        vm.reset()
        ask()
        await waitUntilDone()
        #expect(vm.turns.flatMap(\.artifacts).isEmpty)
    }
}

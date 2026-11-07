import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessArtifactRetryTests {
    @Test(arguments: [false, true]) func createdDocumentReferencesSurviveRetryAndReopening(completes: Bool) async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let create = try chatAgentCall("create_document", arguments: .object(["title": .string("Minutes"), "markdown": .string("Body")]))
        let responses = [AgentTurnResponse(text: "", toolCalls: [create])] + (completes ? [AgentTurnResponse(text: "Done")] : [])
        let model = ChatAgentModel(responses)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model },
                                      harnessService: HarnessChatService(limits: AgentLimits(maxTurns: 1)))
        vm.configure(meeting: meeting, modelContext: context)
        func ask() {
            vm.send(question: "Write minutes", transcriptText: nil, candidates: [], provider: .openAI, model: "gpt-4o")
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
        ask()
        await waitUntilDone()
        #expect(vm.turns.flatMap(\.artifacts) == [ChatArtifactReference(artifact)])
        #expect((vm.error == nil) == completes)
        let session = try #require(vm.pastSessions().first)
        #expect(session.turns.flatMap { $0.artifacts ?? [] } == [ChatArtifactReference(artifact)])
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

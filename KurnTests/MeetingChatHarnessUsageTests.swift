import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessUsageTests {
    @Test(arguments: [false, true]) func absentUsageStaysNilWhileExplicitZeroIsPreserved(reported: Bool) async {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Answer", usage: reported ? AgentUsage() : nil)])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "Question", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
        #expect(vm.error == nil)
        #expect((vm.turns.last?.usage != nil) == reported)
        #expect((vm.turns.last?.costUSD != nil) == reported)
        #expect((vm.pastSessions().first?.turns.last?.usage != nil) == reported)
    }
}

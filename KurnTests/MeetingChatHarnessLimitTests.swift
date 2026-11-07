import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessLimitTests {
    @Test(arguments: [AgentRunStopReason.turnLimit, .toolCallLimit, .costLimit, .outputLimit])
    func emptyLimitedRepliesKeepStepsOnTheRetryableQuestionWithoutSavingAnAssistant(reason: AgentRunStopReason) async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let limits: AgentLimits
        switch reason {
        case .turnLimit: limits = AgentLimits(maxTurns: 0)
        case .toolCallLimit: limits = AgentLimits(maxToolCalls: 0)
        case .costLimit: limits = AgentLimits(maxCostUSD: 0)
        default: limits = AgentLimits()
        }
        let model = ChatAgentModel([AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources")],
                                                      stopReason: reason == .outputLimit ? .maxTokens : .endTurn)])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: HarnessChatService(limits: limits))
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "Question", transcriptText: nil, candidates: [], provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
        #expect(vm.error == nil)
        #expect(vm.retryableQuestion == "Question")
        #expect(vm.turns.map(\.role) == [.user])
        #expect(vm.turns.last?.steps.last?.stopReason == reason)
        let session = try #require(vm.pastSessions().first)
        #expect(session.turns.map(\.role) == [.user])
        #expect(session.turns.last?.steps?.last?.stopReason == reason)
        vm.load(session: session)
        #expect(vm.retryableQuestion == "Question")
        #expect(vm.turns.last?.steps.last?.stopReason == reason)
        vm.dropRetryableQuestion()
        #expect(vm.turns.isEmpty)
    }
}

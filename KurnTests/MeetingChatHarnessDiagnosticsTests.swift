import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessDiagnosticsTests {
    @Test func thirteenMeetingsUseTheTerraCatalogAndPreserveOneLimitWithTenBlockedCalls() async throws {
        let context = ModelContext(TestModelContainer.make())
        for index in 0..<13 {
            let meeting = MeetingFixtures.transcribed("Synthetic meeting \(index)", in: context)
            let summary = Summary(meeting: meeting, provider: .openAI)
            context.insert(summary)
            meeting.summaries.append(summary)
        }
        try context.save()
        let calls = try (0..<61).map { try chatAgentCall("list_sources", id: String($0)) }
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: calls, usage: AgentUsage(inputTokens: 33_000, outputTokens: 1_000)),
            AgentTurnResponse(text: "Partial answer from the selected sources.")
        ])
        let suite = "MeetingChatHarnessDiagnosticsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HarnessChatService(limits: AgentLimits(maxTurns: 14, maxToolCalls: 51, wrapUpOnLimit: true), contextWindows: ModelContextWindowStore(defaults: defaults))
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: service)
        vm.configure(meeting: nil, modelContext: context)
        vm.send(question: "Compare the meetings", provider: .openAI, model: "gpt-6.1-terra")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
        #expect(vm.error == nil)
        let session = try #require(vm.pastSessions().first)
        let steps = try #require(session.turns.last?.steps)
        let resolution = try #require(steps.compactMap(\.contextResolution).first)
        #expect(resolution.source == .fixedTable)
        #expect(resolution.contextWindowTokens == 1_050_000)
        let trace = steps.compactMap(\.diagnostic)
        #expect(trace.first?.metrics[.maxToolCalls] == 51)
        #expect(trace.first?.metrics[.maxTurns] == 14)
        #expect(trace.filter { $0.kind == .limitReached }.map(\.stopReason) == [.toolCallLimit])
        #expect(trace.filter { $0.kind == .toolSkipped }.count == 10)
        #expect(!trace.contains { $0.kind == .compactionStarted })
        vm.load(session: session)
        #expect(vm.turns.last?.steps == steps)
        #expect(await model.requests.count == 2)
    }
}

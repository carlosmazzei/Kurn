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
        #expect(trace.allSatisfy { $0.correlation?.sessionID == session.id.uuidString })
        let requests = await model.requests
        let requestIDs = Set(requests.compactMap { $0.identity?.id })
        #expect(requestIDs.count == 2)
        #expect(trace.filter { $0.kind == .requestStarted }.allSatisfy { requestIDs.contains($0.correlation?.requestID ?? "") })
        #expect(Set(trace.filter { $0.kind == .toolRequested }.compactMap { $0.correlation?.invocationID }).count == 61)
        #expect(trace.first?.metrics[.maxToolCalls] == 51)
        #expect(trace.first?.metrics[.maxTurns] == 14)
        #expect(trace.filter { $0.kind == .limitReached }.map(\.stopReason) == [.toolCallLimit])
        #expect(trace.filter { $0.kind == .toolSkipped }.count == 10)
        #expect(!trace.contains { $0.kind == .compactionStarted })
        vm.load(session: session)
        #expect(vm.turns.last?.steps == steps)
        #expect(await model.requests.count == 2)
    }
    @Test func reloadedConversationKeepsSessionCorrelationAndNewChatGetsNewIdentity() async throws {
        let context = ModelContext(TestModelContainer.make())
        _ = MeetingFixtures.transcribed("Meeting", in: context)
        let model = ChatAgentModel((0..<3).map { AgentTurnResponse(text: "Answer \($0)") })
        let service = HarnessChatService(refreshMetadata: { _, _, _ in .unsupported })
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: service)
        vm.configure(meeting: nil, modelContext: context)
        #expect(vm.pastSessions().isEmpty)
        vm.send(question: "First", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        let first = try #require(vm.pastSessions().first)
        let firstTrace = first.turns.flatMap { $0.steps ?? [] }.compactMap(\.diagnostic)
        vm.reset()
        vm.load(session: first)
        vm.send(question: "Continue", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(vm.error == nil)
        let continued = first.turns.last?.steps?.compactMap(\.diagnostic) ?? []
        #expect(!continued.isEmpty && continued.allSatisfy { $0.correlation?.sessionID == first.id.uuidString })
        #expect(continued.first?.runID != firstTrace.first?.runID)
        vm.reset()
        vm.send(question: "New", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        let other = try #require(vm.pastSessions().first)
        #expect(other.id != first.id && vm.pastSessions().count == 2)
        let newTrace = other.turns.last?.steps?.compactMap(\.diagnostic) ?? []
        #expect(!newTrace.isEmpty && newTrace.allSatisfy { $0.correlation?.sessionID == other.id.uuidString })
    }

}

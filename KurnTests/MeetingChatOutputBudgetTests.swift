import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatOutputBudgetTests {
    @Test func thirtyThreeSourcesRecoverFromOutputLimitAndPersistOnlyTheCompletedArtifact() async throws {
        let context = ModelContext(TestModelContainer.make())
        var meetings: [Meeting] = []
        var calls: [AgentToolCall] = []
        for offset in [0, 10, 20, 30] {
            calls.append(try chatAgentCall("list_sources", arguments: .object(["offset": .number(Double(offset))])))
        }
        for index in 0..<33 {
            let meeting = MeetingFixtures.transcribed("Meeting \(index)", lines: [String(repeating: "a", count: 4_000)], in: context)
            context.insert(Summary(meeting: meeting, sections: [SummarySection(title: "Notes", body: String(repeating: "b", count: 2_000))], provider: .openAI))
            meetings.append(meeting)
            calls.append(try chatAgentCall("read_summary", arguments: .object(["meetingID": .string(meeting.id.uuidString)])))
            if index < 6 {
                calls.append(try chatAgentCall("read_transcript", arguments: .object(["meetingID": .string(meeting.id.uuidString)])))
            }
        }
        try context.save()
        #expect(calls.count == 43)
        let create = try chatAgentCall("create_document", arguments: .object(["title": .string("Report"), "markdown": .string("# Decisions")]))
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: calls, usage: AgentUsage(inputTokens: 3_000, outputTokens: 1_000)),
            AgentTurnResponse(text: "", toolCalls: [create], usage: AgentUsage(inputTokens: 54_879, outputTokens: 32_768, reasoningTokens: 32_768),
                              stopReason: .maxTokens),
            AgentTurnResponse(text: "Checkpoint"),
            AgentTurnResponse(text: "", toolCalls: [create]), AgentTurnResponse(text: "Report created")
        ])
        let suite = "MeetingChatOutputBudgetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HarnessChatService(contextWindows: ModelContextWindowStore(defaults: defaults))
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: service)
        vm.configure(meeting: nil, modelContext: context)
        vm.updateScope(ChatSourceScope(kind: .meetings, selectedIDs: Set(meetings.map(\.id))))
        vm.send(question: "Create a report", provider: .openAI, model: "gpt-6.1-terra")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
        #expect(vm.error == nil)
        #expect(vm.turns.last?.text == "Report created")
        #expect(vm.artifacts.count == 1)
        #expect(vm.artifacts.first?.version == 1)
        let requests = await model.requests
        #expect(requests.map(\.maxOutputTokens) == Array(repeating: 128_000, count: 5))
        #expect(requests[1].messages != requests[3].messages)
        let session = try #require(vm.pastSessions().first)
        let steps = try #require(session.turns.last?.steps)
        let facts = steps.compactMap(\.diagnostic)
        #expect(facts.first?.metrics[.selectedSources] == 33)
        #expect(facts.filter { $0.kind == .outputRetryStarted }.count == 1)
        #expect(!facts.contains { $0.kind == .limitReached })
        let skipped = facts.filter { $0.kind == .toolSkipped }
        #expect(skipped.count == 1 && skipped.first?.stopReason == .outputLimit)
        #expect(facts.filter { $0.kind == .compactionStarted && $0.metrics[.forced] == 1 }.count == 1)
        let creations = steps.filter { $0.toolName == "create_document" }
        #expect(creations.count == 2)
        #expect(creations.filter { $0.status == .failed }.count == 1)
        #expect(creations.filter { $0.status == .finished }.count == 1)
        #expect(creations.allSatisfy { $0.callID == create.id })
        #expect(steps.filter { $0.kind == .tool && $0.status == .finished }.count == 44)
        #expect(steps.filter { $0.kind == .tool && $0.status == .failed }.count == 1)
        #expect(facts.last?.metrics[.toolCalls] == 44 && facts.last?.metrics[.blockedCalls] == 1)
        #expect(vm.artifacts.first?.markdown == "# Decisions")
        #expect(steps.last?.stopReason == .completed)
        #expect(try session.harnessSnapshot().artifacts == vm.artifacts)
        vm.load(session: session)
        #expect(vm.turns.last?.steps == steps)
        #expect(vm.scope.selectedIDs == Set(meetings.map(\.id)))
        #expect(vm.artifacts.count == 1)
    }
}

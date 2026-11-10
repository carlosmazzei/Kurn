import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatWorkloadTests {
    @Test func workloadCountsOnlyTheFrozenSourcesAndAllowedParts() throws {
        let context = ModelContext(TestModelContainer.make())
        let selected = MeetingFixtures.transcribed("Selected", lines: [String(repeating: "a", count: 16_001)], in: context)
        let excluded = MeetingFixtures.transcribed("Excluded", lines: [String(repeating: "b", count: 100_000)], in: context)
        context.insert(Summary(meeting: selected, sections: [SummarySection(title: "Notes", body: "Short")], provider: .openAI))
        try context.save()
        let reader = LibraryChatSourceReader(context: context,
            scope: ChatSourceScope(kind: .library, parts: [.summary], partOverrides: [excluded.id: [.transcript]]))
        let workload = try reader.workload(allowedIDs: [selected.id])
        #expect(workload.sourceCount == 1)
        #expect(workload.readableParts == 1)
        #expect(workload.estimatedReadPages == 1)
    }

    @Test func thirteenMeetingWorkloadCompletesSixtyEightCallsWithoutClippingOrEarlyCompaction() async throws {
        let context = ModelContext(TestModelContainer.make())
        var meetings: [Meeting] = []
        var calls = [try chatAgentCall("list_sources"), try chatAgentCall("list_sources", arguments: .object(["offset": .number(10)]))]
        for index in 0..<13 {
            let meeting = MeetingFixtures.transcribed("Meeting \(index)", lines: Array(repeating: String(repeating: "a", count: 2_000), count: 4),
                                                       in: context)
            context.insert(Summary(meeting: meeting, sections: [SummarySection(title: "Summary", body: String(repeating: "b", count: 1_000))],
                                   provider: .openAI))
            meetings.append(meeting)
            calls.append(try chatAgentCall("read_summary", arguments: .object(["meetingID": .string(meeting.id.uuidString)])))
            for offset in 0..<4 {
                calls.append(try chatAgentCall("read_transcript", arguments: .object([
                    "meetingID": .string(meeting.id.uuidString), "offset": .number(Double(offset)), "limit": .number(1)
                ])))
            }
        }
        calls.append(try chatAgentCall("create_document", arguments: .object(["title": .string("Report"), "markdown": .string("Combined findings")])))
        try context.save()
        #expect(calls.count == 68)
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: calls, usage: AgentUsage(inputTokens: 2_000, outputTokens: 6_000)),
            AgentTurnResponse(text: "Report created", usage: AgentUsage(inputTokens: 33_000, outputTokens: 100))
        ])
        let suite = "MeetingChatWorkloadTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HarnessChatService(contextWindows: ModelContextWindowStore(defaults: defaults))
        let workspace = ChatDocumentWorkspace()
        let events = try await service.events(model: model, provider: .openAI, modelIdentifier: "gpt-6.1-terra",
            context: context, scope: ChatSourceScope(kind: .meetings, selectedIDs: Set(meetings.map(\.id))),
            workspace: workspace, history: [], question: "Read all selected sources and create a report")
        var trace: [AgentDiagnostic] = []
        var outcome: AgentRunOutcome?
        for try await event in events {
            if case .diagnostic(let item) = event { trace.append(item) }
            if case .runFinished(let item) = event { outcome = item }
        }
        #expect(outcome?.stopReason == .completed)
        #expect(trace.first?.metrics[.selectedSources] == 13)
        #expect(trace.first?.metrics[.selectedParts] == 26)
        #expect(trace.first?.metrics[.estimatedReadPages] == 26)
        #expect(trace.first?.metrics[.maxToolCalls] == 90)
        #expect(trace.filter { $0.kind == .toolFinished }.count == 68)
        #expect(trace.filter { $0.kind == .toolFinished }.allSatisfy { $0.metrics[.isError] == 0 })
        #expect(trace.filter { $0.kind == .toolFinished }.reduce(0) { $0 + ($1.metrics[.mutationsCommitted] ?? 0) } == 1)
        #expect(trace.filter { $0.kind == .toolFinished }.reduce(0) { $0 + ($1.metrics[.returnedScalars] ?? 0) } >= 117_000)
        #expect(!trace.contains { [.limitReached, .toolSkipped, .compactionStarted, .payloadClipped].contains($0.kind) })
        #expect(await workspace.snapshot().count == 1)
        let session = try #require(try context.fetch(FetchDescriptor<ChatSession>()).first)
        let committed = try session.harnessSnapshot()
        let published = await workspace.snapshot()
        #expect(committed.artifacts == published)
        #expect(session.harnessRecords.count == 1 && session.harnessRevisions.count == 1)
        #expect(await model.requests.count == 2)
    }
}

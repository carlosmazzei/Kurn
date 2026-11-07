import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessHistoryTests {
    @Test func legacyCitationExcerptsAreNotReplayedIntoNarrowedHarnessScope() async throws {
        let context = ModelContext(TestModelContainer.make())
        let first = MeetingFixtures.transcribed("Meeting A", in: context)
        let excluded = MeetingFixtures.transcribed("Meeting B", in: context)
        let excerpt = "SECRET EXCERPT FROM EXCLUDED MEETING B"
        let hit = SemanticSearchService.Hit(chunkID: UUID(), meetingID: excluded.id, recordingID: UUID(), text: excerpt,
                                            start: 10, end: 20, speakerLabel: "Speaker", score: 1, meetingTitle: excluded.title)
        let prior = [MeetingChatViewModel.Turn(role: .user, text: "Earlier question"),
                     MeetingChatViewModel.Turn(role: .assistant, text: "Earlier answer", citations: [hit])]
        #expect(MeetingChatViewModel.buildHistory(from: prior).contains { $0.content.contains(excerpt) })
        let session = ChatSession(meeting: nil, title: "Legacy conversation")
        session.turns = prior.map(PersistedChatTurn.init)
        context.insert(session)
        let model = ChatAgentModel([AgentTurnResponse(text: "Scoped answer")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: session)
        vm.updateScope(ChatSourceScope(kind: .meetings, selectedIDs: [first.id], parts: [.transcript]))
        vm.send(question: "Question about A", transcriptText: nil, candidates: [], provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
        #expect(vm.error == nil)
        let request = try #require(await model.requests.first)
        #expect(request.messages == [.user("Earlier question"), .assistant(text: "Earlier answer", toolCalls: []), .user("Question about A")])
        #expect(!String(describing: request).contains(excerpt))
    }
}

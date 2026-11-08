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
        // A conversation saved by the old chat still carries its retrieval citations.
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","role":"user","text":"Earlier question","citations":[]},
         {"id":"\(UUID().uuidString)","role":"assistant","text":"Earlier answer","citations":[{"meetingID":"\(excluded.id.uuidString)",
         "recordingID":"\(UUID().uuidString)","meetingTitle":"Meeting B","start":10,"speakerLabel":"Speaker","text":"\(excerpt)"}]}]
        """
        let session = ChatSession(meeting: nil, title: "Legacy conversation")
        session.turns = try JSONDecoder().decode([PersistedChatTurn].self, from: Data(legacyJSON.utf8))
        context.insert(session)
        let model = ChatAgentModel([AgentTurnResponse(text: "Scoped answer")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: nil, modelContext: context)
        vm.load(session: session)
        #expect(vm.turns.map(\.text) == ["Earlier question", "Earlier answer"])
        vm.updateScope(ChatSourceScope(kind: .meetings, selectedIDs: [first.id], parts: [.transcript]))
        vm.send(question: "Question about A", provider: .openAI, model: "gpt-4o")
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
        #expect(vm.error == nil)
        let request = try #require(await model.requests.first)
        #expect(request.messages == [.user("Earlier question"), .assistant(text: "Earlier answer", toolCalls: []), .user("Question about A")])
        #expect(!String(describing: request).contains(excerpt))
    }
}

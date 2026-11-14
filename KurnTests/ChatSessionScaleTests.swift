import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// Qualification of a long conversation: one of a thousand saved entries opens, read back whole.
/// The times go to `[session-scale]` lines for comparison between runs; like the pipeline
/// evaluation, no threshold is invented for them.
@MainActor
struct ChatSessionScaleTests {
    static let exchanges = 500

    @Test func aConversationOfAThousandEntriesOpens() throws {
        let container = TestModelContainer.make()
        let context = ModelContext(container)
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let session = ChatSession(meeting: meeting, title: "Long")
        context.insert(session)
        let turns = (0..<Self.exchanges).flatMap { index in [
            PersistedChatTurn(id: UUID(), role: .user, text: "Question \(index)", usage: nil, costUSD: nil, elapsedSeconds: nil),
            PersistedChatTurn(id: UUID(), role: .assistant, text: "Answer \(index) [0:\(String(format: "%02d", index % 60))]",
                              usage: nil, costUSD: nil, elapsedSeconds: nil)
        ] }
        let clock = ContinuousClock()
        let write = try clock.measure {
            try SwiftDataAgentSessionStore(context: context).writePresentation(session, turns: turns, scope: nil, artifacts: [])
        }
        #expect(session.harnessEntries.count >= Self.exchanges * 2)

        var projected = 0
        let projection = try clock.measure { projected = try SwiftDataAgentSessionStore.projection(session).turns.count }
        #expect(projected == Self.exchanges * 2)

        // Opening reads the conversation back through a context that has never seen it, as a
        // relaunch would: the fetch is part of the time.
        try context.save()
        let sessionID = session.id
        let reader = ModelContext(container)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in nil })
        var opened: ChatSession?
        let open = try clock.measure {
            let fetched = try reader.fetch(FetchDescriptor<ChatSession>(predicate: #Predicate { $0.id == sessionID })).first
            opened = fetched
            if let fetched, let owner = fetched.meeting {
                vm.configure(meeting: owner, modelContext: reader)
                vm.load(session: fetched)
            }
        }
        #expect(opened != nil && opened !== session)
        #expect(vm.turns.count == Self.exchanges * 2)
        #expect(vm.turns.last?.text == "Answer \(Self.exchanges - 1) [0:\(String(format: "%02d", (Self.exchanges - 1) % 60))]")
        print("[session-scale] entries=\(session.harnessEntries.count) write_ms=\(LiveProviderSmokeTests.milliseconds(write))"
              + " projection_ms=\(LiveProviderSmokeTests.milliseconds(projection)) open_ms=\(LiveProviderSmokeTests.milliseconds(open))")
    }
}

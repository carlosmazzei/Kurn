import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct AuthorizedChatSourceReaderTests {
    @Test func selectedPartsAndRevisionsStayFixedWhileNewSourcesAndEditsAppear() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Original", in: context)
        let summary = Summary(meeting: meeting, sections: [SummarySection(title: "Facts", body: "Original body", items: [])], provider: .openAI)
        context.insert(summary); try context.save()
        let scope = ChatSourceScope(kind: .library, parts: [.summary])
        let reader = try LibraryChatSourceReader(context: context, scope: scope).authorizedSnapshot()
        let revision = reader.revisions[meeting.id]
        _ = MeetingFixtures.transcribed("New source", in: context)
        meeting.title = "Changed"
        summary.sections = [SummarySection(title: "Facts", body: "Changed body", items: [])]
        try context.save()
        #expect(try await reader.listSources().map(\.title) == ["Original"])
        #expect(try await reader.readSummary(meetingID: meeting.id)?.contains("Original body") == true)
        #expect(try await reader.readTranscript(meetingID: meeting.id, offset: 0, limit: 10).total == 0)
        #expect(reader.revisions[meeting.id] == revision && revision?.count == 64)
        let fresh = try LibraryChatSourceReader(context: context, scope: scope).authorizedSnapshot()
        #expect(fresh.revisions[meeting.id] != revision)
    }

    @Test func deletedSourceFailsRatherThanReturningAnEmptyPage() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Source", in: context)
        try context.save()
        let id = meeting.id
        let reader = try LibraryChatSourceReader(context: context, scope: ChatSourceScope(kind: .library)).authorizedSnapshot()
        context.delete(meeting); try context.save()
        await #expect(throws: (any Error).self) { try await reader.listSources() }
        await #expect(throws: (any Error).self) { try await reader.readTranscript(meetingID: id, offset: 0, limit: 10) }
    }
}

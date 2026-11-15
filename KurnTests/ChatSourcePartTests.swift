import AgentHarness
import Foundation
import Testing
import KurnCore
@testable import Kurn

private actor PartSourceReader: ChatSourceReader {
    let ids: [UUID]
    private(set) var reads: [UUID] = []
    private(set) var searched: Set<UUID> = []
    let attachmentID = UUID()

    init(ids: [UUID]) { self.ids = ids }
    func listSources() -> [ChatSource] {
        ids.map { ChatSource(id: $0, title: "Source", date: .distantPast, duration: 10,
                            availability: ChatSourceAvailability(summary: true, wiki: true, attachments: true)) }
    }
    func search(query: String, meetingIDs: Set<UUID>, limit: Int) -> [ChatSourcePassage] {
        searched = meetingIDs
        return ids.map { ChatSourcePassage(meetingID: $0, timestamp: 0, speaker: "Pat", text: $0.uuidString) }
    }
    func readTranscript(meetingID: UUID, offset: Int, limit: Int) -> ChatTranscriptPage {
        reads.append(meetingID)
        return ChatTranscriptPage(passages: [], total: 0)
    }
    func readSummary(meetingID: UUID) -> String? { reads.append(meetingID); return "Summary" }
    func readWiki(meetingID: UUID) -> String? { reads.append(meetingID); return "Wiki" }
    func listAttachments(meetingID: UUID) -> [ChatSourceAttachment] {
        reads.append(meetingID)
        return [ChatSourceAttachment(id: attachmentID, name: "Attachment")]
    }
    func readAttachment(meetingID: UUID, attachmentID: UUID) -> String? { reads.append(meetingID); return "Text" }
}

@Suite struct ChatSourcePartTests {
    @Test(arguments: ["read_transcript", "read_summary", "read_wiki", "read_attachment"])
    func readsRejectDisabledPartsBeforeReading(name: String) async throws {
        let first = UUID(), second = UUID()
        let reader = PartSourceReader(ids: [first, second])
        let scope = ChatSourceScope(kind: .library, parts: [], partOverrides: [first: Set(ChatSourcePart.allCases)])
        let tools = ChatSourceTools.make(reader: reader, allowedMeetingIDs: [first, second], scope: scope)
        let tool = try #require(tools.first { $0.spec.name == name })
        let denied = try await tool.execute(.object(["meetingID": .string(second.uuidString)]))
        #expect(denied.isError)
        #expect(await reader.reads.isEmpty)
        let allowed = try await tool.execute(.object(["meetingID": .string(first.uuidString)]))
        #expect(!allowed.isError)
        #expect(await reader.reads == [first])
        if name == "read_attachment" {
            let text = try await tool.execute(.object(["meetingID": .string(first.uuidString),
                                                       "attachmentID": .string(reader.attachmentID.uuidString)]))
            #expect(!text.isError)
        }
    }

    @Test(arguments: ChatSourcePart.allCases) func onlyEligibleToolsAreOffered(part: ChatSourcePart) {
        let id = UUID(), outsider = UUID()
        let tools = ChatSourceTools.make(reader: PartSourceReader(ids: [id]), allowedMeetingIDs: [id],
            scope: ChatSourceScope(kind: .library, parts: [part], partOverrides: [outsider: Set(ChatSourcePart.allCases)]))
        let names = Set(tools.map(\.spec.name))
        let expected: Set<String>
        switch part {
        case .transcript: expected = ["list_sources", "search", "read_transcript"]
        case .summary: expected = ["list_sources", "read_summary"]
        case .wiki: expected = ["list_sources", "read_wiki"]
        case .attachments: expected = ["list_sources", "read_attachment"]
        }
        #expect(names == expected)
        #expect(tools.allSatisfy { !$0.requiresConfirmation })
    }

    @Test func emptyScopeAndEmptyPartsOnlyOfferListing() async throws {
        let id = UUID()
        let reader = PartSourceReader(ids: [id])
        let selections: [Set<UUID>] = [[], [id]]
        for ids in selections {
            let tools = ChatSourceTools.make(reader: reader, allowedMeetingIDs: ids,
                                            scope: ChatSourceScope(kind: .library, parts: []))
            #expect(tools.map(\.spec.name) == ["list_sources"])
            #expect(try await tools[0].execute(.object([:])).isError == false)
        }
    }

    @Test func listingMasksAvailabilityAndReportsOverrides() async throws {
        let first = UUID(), second = UUID(), outsider = UUID()
        let reader = PartSourceReader(ids: [first, second, outsider])
        let tools = ChatSourceTools.make(reader: reader, allowedMeetingIDs: [first, second],
            scope: ChatSourceScope(kind: .library, parts: [.summary], partOverrides: [second: [.wiki, .attachments]]))
        let output = try await tools[0].execute(.object([:]))
        let lines = output.content.split(separator: "\n").map(String.init)
        let firstLine = try #require(lines.first { $0.contains(first.uuidString) })
        let secondLine = try #require(lines.first { $0.contains(second.uuidString) })
        #expect(firstLine.hasSuffix(" | readable: summary"))
        #expect(secondLine.hasSuffix(" | readable: wiki, attachments"))
        #expect(lines.count == 4)
        #expect(lines.last == "page: items 1–2 of 2; end")
        #expect(!output.content.contains(outsider.uuidString))
    }

    @Test func searchOnlyRetrievesAndReturnsTranscriptEnabledMeetings() async throws {
        let first = UUID(), second = UUID(), outsider = UUID()
        let reader = PartSourceReader(ids: [first, second, outsider])
        let tools = ChatSourceTools.make(reader: reader, allowedMeetingIDs: [first, second],
            scope: ChatSourceScope(kind: .library, parts: [.summary], partOverrides: [first: [.transcript]]))
        let search = try #require(tools.first { $0.spec.name == "search" })
        let result = try await search.execute(.object(["query": .string("Decision")]))
        #expect(await reader.searched == [first])
        #expect(result.content.contains(first.uuidString))
        #expect(!result.content.contains(second.uuidString))
        #expect(!result.content.contains(outsider.uuidString))
        let missing = ChatSourceTools.make(reader: PartSourceReader(ids: []), allowedMeetingIDs: [first],
                                          scope: ChatSourceScope(kind: .library, parts: [.transcript]))
        let empty = try await #require(missing.first { $0.spec.name == "search" }).execute(.object(["query": .string("Decision")]))
        #expect(!empty.isError)
        #expect(empty.content.hasSuffix("page: no items of 0; end"))
    }

    @Test func harnessRecoversFromPartDenial() async throws {
        let first = UUID(), second = UUID()
        let reader = PartSourceReader(ids: [first, second])
        let tools = ChatSourceTools.make(reader: reader, allowedMeetingIDs: [first, second],
            scope: ChatSourceScope(kind: .library, parts: [.summary], partOverrides: [first: []]))
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [
            agentCall("1", name: "read_summary", raw: "{\"meetingID\":\"\(first)\"}"),
            agentCall("2", name: "read_summary", raw: "{\"meetingID\":\"\(second)\"}")
        ]), AgentTurnResponse(text: "Used only the permitted summary.")])
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model), tools: tools))
        #expect(outcome.stopReason == .completed)
        #expect(await reader.reads == [second])
        #expect(outcome.messages.contains { if case .toolResult(_, _, _, true) = $0.legacyProjection { return true }; return false })
    }
}

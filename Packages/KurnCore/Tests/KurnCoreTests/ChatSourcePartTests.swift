import AgentHarness
import Foundation
import Testing
@testable import KurnCore

@Suite struct ChatSourceScopeTests {
    @Test func globalSelectionAndOverridesRoundTrip() throws {
        let first = UUID(), second = UUID(), other = UUID()
        let scope = ChatSourceScope(kind: .meetings, selectedIDs: [first, second], parts: [.summary],
                                    partOverrides: [first: [.wiki, .attachments], second: []])
        #expect(scope.parts(for: first) == [.wiki, .attachments])
        #expect(scope.parts(for: second).isEmpty)
        #expect(scope.parts(for: other) == [.summary])
        let data = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(ChatSourceScope.self, from: data) == scope)
        #expect(!String(decoding: data, as: UTF8.self).contains("includeWikis"))
        #expect(Set(ChatSourcePart.allCases) == [.transcript, .summary, .wiki, .attachments])
    }

    @Test(arguments: [true, false]) func legacyDecode(wiki: Bool) throws {
        let id = UUID()
        let payload = "{\"kind\":\"folders\",\"selectedIDs\":[\"\(id)\"],\"includeWikis\":\(wiki)}"
        let scope = try JSONDecoder().decode(ChatSourceScope.self, from: Data(payload.utf8))
        #expect(scope.kind == .folders)
        #expect(scope.selectedIDs == [id])
        #expect(scope.parts == (wiki ? Set(ChatSourcePart.allCases) : ChatSourceScope.defaultParts))
        #expect(scope.partOverrides.isEmpty)
    }

    @Test func missingFieldsAndExplicitEmptyParts() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(ChatSourceScope.self, from: Data("{\"kind\":\"library\"}".utf8))
        #expect(defaults.parts == ChatSourceScope.defaultParts)
        #expect(defaults.selectedIDs.isEmpty)
        let explicit = try decoder.decode(ChatSourceScope.self,
            from: Data("{\"kind\":\"library\",\"parts\":[],\"includeWikis\":true}".utf8))
        #expect(explicit.parts.isEmpty)
    }

    @Test func legacyAPIOnlyChangesGlobalSelection() {
        let id = UUID()
        var scope = ChatSourceScope(kind: .tags, includeWikis: true)
        #expect(scope.includeWikis)
        scope.partOverrides[id] = [.wiki]
        scope.includeWikis = false
        #expect(!scope.parts.contains(.wiki))
        #expect(scope.parts(for: id) == [.wiki])
        scope.includeWikis = true
        #expect(scope.parts == Set(ChatSourcePart.allCases))
        #expect(ChatSourceScope(kind: .library, includeWikis: false).parts == ChatSourceScope.defaultParts)
    }

    @Test(arguments: ["{}", "{\"kind\":\"bad\"}", "{\"kind\":\"library\",\"parts\":[\"secret\"]}",
                      "{\"kind\":\"library\",\"includeWikis\":\"yes\"}"])
    func invalidPayloads(payload: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ChatSourceScope.self, from: Data(payload.utf8)) }
    }
}

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
        let json = try JSONValue.parse(output.content)
        guard case .object(let page) = json, case .array(let items) = page["items"] else { Issue.record("Missing page"); return }
        #expect(items.count == 2)
        for item in items {
            guard case .object(let value) = item else { Issue.record("Missing source"); return }
            let isFirst = value["id"] == .string(first.uuidString)
            #expect(value["allowedParts"] == .array(isFirst ? [.string("summary")] : [.string("attachments"), .string("wiki")]))
            #expect(value["hasSummary"] == .bool(isFirst))
            #expect(value["hasWiki"] == .bool(!isFirst))
            #expect(value["hasAttachments"] == .bool(!isFirst))
            #expect(value["hasTranscript"] == .bool(false))
        }
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
        #expect(empty.content.contains("\"items\":[]"))
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
        #expect(outcome.messages.contains { if case .toolResult(_, _, _, true) = $0 { return true }; return false })
    }
}

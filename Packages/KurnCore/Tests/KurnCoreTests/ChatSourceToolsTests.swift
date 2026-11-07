import AgentHarness
import Foundation
import Testing
@testable import KurnCore

private struct FakeSourceReader: ChatSourceReader {
    let id: UUID
    let outsider = UUID()
    let attachmentID = UUID()
    var fails = false
    var empty = false
    var missingText = false
    var cancelled = false
    func listSources() async throws -> [ChatSource] {
        if cancelled { throw CancellationError() }
        if fails { throw ScriptedAgentModel.Failure.provider }
        if empty { return [] }
        return [id, outsider].map {
            ChatSource(id: $0, title: String(repeating: "title", count: 200), date: .distantPast, duration: 10,
                       tags: Array(repeating: String(repeating: "tag", count: 200), count: 30),
                       folder: "Folder", availability: ChatSourceAvailability(summary: true, wiki: true, attachments: true))
        }
    }
    func search(query: String, meetingIDs: Set<UUID>, limit: Int) async throws -> [ChatSourcePassage] {
        [ChatSourcePassage(meetingID: outsider, timestamp: 0, speaker: "secret", text: "secret")]
            + Array(repeating: ChatSourcePassage(meetingID: id, timestamp: 12, speaker: "Pat",
                                                text: String(repeating: "x", count: 900)), count: 25)
    }
    func readTranscript(meetingID: UUID, offset: Int, limit: Int) async throws -> ChatTranscriptPage {
        ChatTranscriptPage(passages: Array(try await search(query: "", meetingIDs: [], limit: limit).dropFirst().prefix(limit)),
                           total: 25)
    }
    func readSummary(meetingID: UUID) async throws -> String? { String(repeating: "s", count: 9000) }
    func readWiki(meetingID: UUID) async throws -> String? { missingText ? nil : "Wiki" }
    func listAttachments(meetingID: UUID) async throws -> [ChatSourceAttachment] {
        [ChatSourceAttachment(id: attachmentID, name: "Notes")]
    }
    func readAttachment(meetingID: UUID, attachmentID: UUID) async throws -> String? { "Attachment" }
}

@Suite struct ChatSourceToolsTests {
    private let id = UUID()

    private func run(_ name: String, _ arguments: JSONValue, reader: FakeSourceReader? = nil) async throws -> AgentToolOutput {
        let tools = ChatSourceTools.make(reader: reader ?? FakeSourceReader(id: id), allowedMeetingIDs: [id],
                                        scope: ChatSourceScope(kind: .library, parts: Set(ChatSourcePart.allCases)))
        return try await #require(tools.first { $0.spec.name == name }).execute(arguments)
    }

    @Test func scopeRoundTripAndWikiSwitch() throws {
        let scope = ChatSourceScope(kind: .folders, selectedIDs: [id], parts: Set(ChatSourcePart.allCases))
        #expect(try JSONDecoder().decode(ChatSourceScope.self, from: JSONEncoder().encode(scope)) == scope)
        let tools = ChatSourceTools.make(reader: FakeSourceReader(id: id), allowedMeetingIDs: [], includeWikis: false)
        #expect(!tools.contains { $0.spec.name == "read_wiki" })
        #expect(tools.allSatisfy { !$0.requiresConfirmation })
    }

    @Test(arguments: ["list_sources", "search", "read_transcript", "read_summary", "read_wiki", "read_attachment"])
    func happyPathsAndPagination(name: String) async throws {
        var args: [String: JSONValue] = [:]
        if name == "search" { args["query"] = .string("decision") }
        else if name != "list_sources" { args["meetingID"] = .string(id.uuidString) }
        let result = try await run(name, .object(args))
        #expect(!result.isError)
        #expect(result.content.utf8.count < 20000)
        if name == "search" {
            #expect(!result.content.contains("secret"))
            #expect(result.content.contains("truncated"))
            #expect(result.content.contains("nextOffset"))
        }
        if name == "read_summary" { #expect(result.content.contains("8000")) }
    }

    @Test(arguments: ["read_transcript", "read_summary", "read_wiki", "read_attachment"])
    func rejectsScopeAndUnknownMeeting(name: String) async throws {
        let result = try await run(name, .object(["meetingID": .string(UUID().uuidString)]))
        #expect(result.isError)
        #expect(result.content.contains("out-of-scope"))
    }

    @Test(arguments: [JSONValue.null, .object(["extra": .bool(true)]), .object(["offset": .number(-1)]),
                      .object(["limit": .number(0)]), .object(["limit": .number(1.5)]), .object(["limit": .string("1")])])
    func rejectsBadArguments(arguments: JSONValue) async throws {
        #expect(try await run("list_sources", arguments).isError)
    }

    @Test func missingMalformedAndAttachmentArguments() async throws {
        #expect(try await run("search", .object([:])).isError)
        #expect(try await run("search", .object(["query": .string(" ")])).isError)
        #expect(try await run("read_summary", .object(["meetingID": .string("bad")])).isError)
        let reader = FakeSourceReader(id: id)
        let args: [String: JSONValue] = ["meetingID": .string(id.uuidString), "attachmentID": .string(reader.attachmentID.uuidString)]
        #expect(try await run("read_attachment", .object(args), reader: reader).content.contains("Attachment"))
        #expect(try await run("read_attachment", .object(["meetingID": .string(id.uuidString),
                                                         "attachmentID": .string(UUID().uuidString)])).isError)
        #expect(try await run("list_sources", .object([:]), reader: FakeSourceReader(id: id, fails: true)).isError)
        #expect(try await run("list_sources", .object([:]), reader: FakeSourceReader(id: id, empty: true)).content.contains("\"total\":0"))
        #expect(try await run("list_sources", .object(["offset": .number(99)])).content.contains("\"items\":[]"))
        #expect(try await run("read_summary", .object(["meetingID": .string(id.uuidString),
                                                      "offset": .number(8000)])).content.contains("\"nextOffset\":null"))
    }

    @Test func harnessRecoversFromScopeViolation() async throws {
        let calls = [agentCall("1", name: "read_summary", raw: "{\"meetingID\":\"\(UUID())\"}"),
                     agentCall("2", name: "read_wiki", raw: "{\"meetingID\":\"\(id)\"}")]
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls), AgentTurnResponse(text: "Grounded")])
        let tools = ChatSourceTools.make(reader: FakeSourceReader(id: id), allowedMeetingIDs: [id],
                                        scope: ChatSourceScope(kind: .library, parts: Set(ChatSourcePart.allCases)))
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model), tools: tools))
        #expect(outcome.finalText == "Grounded")
        #expect(outcome.messages.contains { message in
            if case .toolResult(_, _, _, let isError) = message { return isError }; return false
        })
    }

    @Test func missingTextAndCancellation() async throws {
        let args = JSONValue.object(["meetingID": .string(id.uuidString)])
        #expect(try await run("read_wiki", args, reader: FakeSourceReader(id: id, missingText: true)).isError)
        await #expect(throws: CancellationError.self) {
            try await run("list_sources", .object([:]), reader: FakeSourceReader(id: id, cancelled: true))
        }
    }
}

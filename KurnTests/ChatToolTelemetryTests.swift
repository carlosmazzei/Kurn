import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ChatToolTelemetryTests {
    private struct Reader: ChatSourceReader {
        let id = UUID()
        let text = String(repeating: "🙂中文e\u{301}\n", count: 5_000)
        func listSources() async throws -> [ChatSource] {
            [ChatSource(id: id, title: String(repeating: "t", count: 800), date: .distantPast, duration: 10,
                        tags: Array(repeating: String(repeating: "x", count: 150), count: 12),
                        folder: String(repeating: "f", count: 700), availability: ChatSourceAvailability(summary: true))]
        }
        func search(query: String, meetingIDs: Set<UUID>, limit: Int) async throws -> [ChatSourcePassage] {
            [ChatSourcePassage(meetingID: id, timestamp: 0, speaker: String(repeating: "s", count: 150),
                               text: String(repeating: "p", count: 1_000))]
        }
        func readTranscript(meetingID: UUID, offset: Int, limit: Int) async throws -> ChatTranscriptPage {
            ChatTranscriptPage(passages: [], total: 0)
        }
        func readSummary(meetingID: UUID) async throws -> String? { text }
        func readWiki(meetingID: UUID) async throws -> String? { nil }
        func listAttachments(meetingID: UUID) async throws -> [ChatSourceAttachment] { [] }
        func readAttachment(meetingID: UUID, attachmentID: UUID) async throws -> String? { nil }
    }

    @Test func listingAndSearchReportExactPreviewLoss() async throws {
        let reader = Reader()
        let tools = ChatSourceTools.make(reader: reader, allowedMeetingIDs: [reader.id], includeWikis: false)
        let listing = try #require(tools.first { $0.spec.name == "list_sources" })
        let metadata = try await listing.execute(.object([:]))
        #expect(metadata.metrics[.omittedScalars] == 1_300)
        #expect(metadata.metrics[.omittedItems] == 2)
        #expect(metadata.metrics[.returnedItems] == 1)
        let search = try #require(tools.first { $0.spec.name == "search" })
        let preview = try await search.execute(.object(["query": .string("facts")]))
        #expect(preview.metrics[.omittedScalars] == 550)
        #expect(preview.metrics[.searchResultLimit] == 100)
        #expect(preview.metrics[.searchWindowFull] == 0)
    }

    @Test func sourceTextPagesRespectBytesAndRecoverAllContent() async throws {
        let reader = Reader()
        let tools = ChatSourceTools.make(reader: reader, allowedMeetingIDs: [reader.id], includeWikis: false)
        let tool = try #require(tools.first { $0.spec.name == "read_summary" })
        var recovered = ""
        var offset = 0
        repeat {
            let output = try await tool.execute(.object(["meetingID": .string(reader.id.uuidString), "offset": .number(Double(offset))]))
            #expect(!output.isError)
            #expect(output.content.utf8.count <= ChatSourceTools.maxOutputBytes)
            let count = try #require(output.metrics[.returnedScalars])
            #expect(count > 0)
            recovered += output.content.components(separatedBy: "\n").dropLast().joined(separator: "\n")
            offset += count
            #expect(output.metrics[.deferredScalars] == reader.text.unicodeScalars.count - offset)
        } while offset < reader.text.unicodeScalars.count
        #expect(recovered == reader.text)
    }

    @Test func documentPagesIncludeHeaderInTheByteBudget() async throws {
        let body = String(repeating: "🙂中文e\u{301}\n", count: 5_000)
        let artifact = ChatDocumentArtifact(title: String(repeating: "🙂", count: 500), markdown: body)
        let workspace = try ChatDocumentWorkspace(artifacts: [artifact])
        let tool = try #require(ChatDocumentTools.make(workspace: workspace).first { $0.spec.name == "read_document" })
        var recovered = ""
        var offset = 0
        repeat {
            let output = try await tool.execute(.object(["document_id": .string(artifact.id.uuidString), "offset": .number(Double(offset))]))
            #expect(output.content.utf8.count <= ChatSourceTools.maxOutputBytes)
            let count = try #require(output.metrics[.returnedScalars])
            #expect(count > 0)
            recovered += output.content.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
            offset += count
        } while offset < body.unicodeScalars.count
        #expect(recovered == body)
    }
}

import AgentHarness
import Foundation
import Testing
@testable import KurnCore

struct ChatTranscriptToolPageTests {
    let meetingID = UUID()

    private func page(_ text: String) -> ChatTranscriptPage {
        ChatTranscriptPage(passages: [ChatSourcePassage(meetingID: meetingID, timestamp: 12, speaker: "Pat", text: text)], total: 1)
    }

    @Test(arguments: [500, 501, 8_000, 8_001, 20_000])
    func fullTextIsRecoverableAtEveryBoundary(length: Int) throws {
        let text = String(repeating: "a", count: length)
        var recovered = ""
        var offset = 0
        while recovered.count < text.count {
            let output = try ChatTranscriptToolPage.output(page(text), offset: 0, textOffset: offset)
            #expect(output.content.utf8.count <= ChatSourceTools.maxOutputBytes)
            let line = try #require(output.content.split(separator: "\n").first { $0.hasPrefix("[0:12] Pat: ") })
            recovered += line.dropFirst("[0:12] Pat: ".count)
            offset = recovered.unicodeScalars.count
            if offset < length {
                #expect(output.content.contains("next offset: 0; textOffset: \(offset)"))
            } else { #expect(output.content.contains("page: end")) }
        }
        #expect(recovered == text)
    }

    @Test func byteBudgetPreservesUnicodeAndContinuation() throws {
        let text = String(repeating: "🙂é", count: 9_000)
        let first = try ChatTranscriptToolPage.output(page(text), offset: 0, textOffset: 0)
        let count = try #require(first.metrics[.returnedScalars])
        #expect(count > 500)
        #expect(first.content.utf8.count <= ChatSourceTools.maxOutputBytes)
        #expect(first.metrics[.hasMore] == 1)
        #expect(first.content.contains("next offset: 0; textOffset: \(count)"))
        let second = try ChatTranscriptToolPage.output(page(text), offset: 0, textOffset: count)
        #expect(!second.isError)
        #expect(second.content.utf8.count <= ChatSourceTools.maxOutputBytes)
        #expect(throws: ChatTranscriptToolPage.InvalidOffset.self) {
            try ChatTranscriptToolPage.output(page(text), offset: 0, textOffset: text.unicodeScalars.count + 1)
        }
    }

    @Test func multiplePassagesAndEmptyPagesAdvanceHonestly() throws {
        let value = ChatTranscriptPage(passages: page("First").passages + page("Second").passages, total: 3)
        let result = try ChatTranscriptToolPage.output(value, offset: 0, textOffset: 0)
        #expect(result.content.contains("First"))
        #expect(result.content.contains("Second"))
        #expect(result.content.contains("next offset: 2; textOffset: 0"))
        let empty = try ChatTranscriptToolPage.output(ChatTranscriptPage(passages: [], total: 0), offset: 0, textOffset: 0)
        #expect(empty.content.contains("page: end"))
        let blank = try ChatTranscriptToolPage.output(page(""), offset: 0, textOffset: 0)
        #expect(blank.metrics[.returnedScalars] == 0)
        #expect(blank.metrics[.hasMore] == 0)
    }
}

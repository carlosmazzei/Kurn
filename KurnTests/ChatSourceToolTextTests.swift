import Foundation
import Testing
import KurnCore
@testable import Kurn

@Suite struct ChatSourceToolTextTests {
    @Test(arguments: [(754.9, "[12:35]"), (754.4, "[12:34]"), (4_512, "[1:15:12]"), (0, "[0:00]"), (-3, "[0:00]"),
                      (Double.nan, "[0:00]")]
        as [(Double, String)])
    func timestampsMatchCitations(seconds: Double, expected: String) {
        #expect(ChatSourceToolText.timestamp(seconds) == expected)
    }

    @Test(arguments: [(2_712.0, "45:12"), (3_725, "1:02:05"), (9.6, "0:10"), (Double.infinity, "0:00")]
        as [(Double, String)])
    func durations(seconds: Double, expected: String) {
        #expect(ChatSourceToolText.duration(seconds) == expected)
    }

    @Test func fieldsStayOnOneLineAndMarkClipping() {
        #expect(ChatSourceToolText.field("  first\nsecond\r\nthird ") == "first second third")
        #expect(ChatSourceToolText.field("abcdef", limit: 3) == "abc [truncated]")
        #expect(ChatSourceToolText.field("abc", limit: 3) == "abc")
    }

    @Test func pageLines() {
        #expect(ChatSourceToolText.pageLine(offset: 0, count: 10, total: 25) == "page: items 1–10 of 25; next offset: 10")
        #expect(ChatSourceToolText.pageLine(offset: 20, count: 5, total: 25) == "page: items 21–25 of 25; end")
        #expect(ChatSourceToolText.pageLine(offset: 30, count: 0, total: 25, unit: "passages")
            == "page: no passages of 25; end")
    }

    @Test func passagesGroupRunsUnderOneMeetingHeader() {
        let first = UUID(), second = UUID()
        let passages = [ChatSourcePassage(meetingID: first, timestamp: 61, speaker: "Ana", text: "One"),
                        ChatSourcePassage(meetingID: first, timestamp: 75, speaker: "Bo\nB", text: "Two\nlines"),
                        ChatSourcePassage(meetingID: second, timestamp: 5, speaker: "Cy", text: "Three"),
                        ChatSourcePassage(meetingID: first, timestamp: 90, speaker: "Ana", text: "Four")]
        #expect(ChatSourceToolText.passages(passages) == [
            "meeting \(first.uuidString):", "[1:01] Ana: One", "[1:15] Bo B: Two lines",
            "meeting \(second.uuidString):", "[0:05] Cy: Three",
            "meeting \(first.uuidString):", "[1:30] Ana: Four"
        ])
    }

    @Test func sourceLines() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 0)
        let tagged = ChatSource(id: id, title: "Plan\nning", date: date, duration: 3_600,
                                tags: (1...12).map { "t\($0)" }, folder: "Ops")
        let line = ChatSourceToolText.source(tagged, readable: [.transcript, .summary])
        #expect(line == "- \(id.uuidString) | Plan ning | 1970-01-01T00:00:00Z | 1:00:00 | folder: Ops | tags: "
            + (1...10).map { "t\($0)" }.joined(separator: ", ") + " (+2 more) | readable: transcript, summary")
        let bare = ChatSource(id: id, title: "Solo", date: date, duration: 59)
        #expect(ChatSourceToolText.source(bare, readable: [])
            == "- \(id.uuidString) | Solo | 1970-01-01T00:00:00Z | 0:59 | readable: none")
    }
}

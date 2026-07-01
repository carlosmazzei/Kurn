//
//  SummaryServiceTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct SummaryServiceTests {

    @Test func assembleTranscriptTextFormatsTimestampSpeakerAndText() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "Hello"),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 65, endTime: 70, text: "Hi there")
        ]
        let text = SummaryService.assembleTranscriptText(from: [(0, segments)])
        #expect(text == "[0:00] Speaker 1: Hello\n[1:05] Speaker 2: Hi there")
    }

    @Test func assembleTranscriptTextFlattensMultipleGroupsInOrder() {
        let groupOne = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "first")]
        let groupTwo = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "second")]
        let text = SummaryService.assembleTranscriptText(from: [(0, groupOne), (0, groupTwo)])
        #expect(text == "[0:00] Speaker 1: first\n[0:00] Speaker 1: second")
    }

    @Test func assembleTranscriptTextShiftsLaterGroupsByOffset() {
        // The second recording starts 60s into the meeting, so its 0:00 segment
        // reads as 1:00 in absolute meeting time.
        let groupOne = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "first")]
        let groupTwo = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "second")]
        let text = SummaryService.assembleTranscriptText(from: [(0, groupOne), (60, groupTwo)])
        #expect(text == "[0:00] Speaker 1: first\n[1:00] Speaker 1: second")
    }

    @Test func assembleTranscriptTextIsEmptyForNoSegments() {
        #expect(SummaryService.assembleTranscriptText(from: []).isEmpty)
        #expect(SummaryService.assembleTranscriptText(from: [(0, [])]).isEmpty)
    }

    @Test func assembleTranscriptTextUsesHourClockForLongMeetings() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 3725, endTime: 3730, text: "still going")
        ]
        let text = SummaryService.assembleTranscriptText(from: [(0, segments)])
        #expect(text == "[1:02:05] Speaker 1: still going")
    }

    @Test func assembleTranscriptTextKeepsEmptyTextSegments() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: ""),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 1, endTime: 2, text: "hi")
        ]
        let text = SummaryService.assembleTranscriptText(from: [(0, segments)])
        #expect(text == "[0:00] Speaker 1: \n[0:01] Speaker 2: hi")
    }

    @Test func generateThrowsWhenTranscriptIsBlank() async {
        let service = SummaryService()
        await #expect(throws: AppError.self) {
            try await service.generate(
                transcriptText: "   \n  ",
                meetingTitle: "Standup",
                provider: .openAI,
                model: "gpt-4o",
                template: .general
            )
        }
    }

    // MARK: - splitTranscript (staged summarization)

    @Test func splitTranscriptReturnsSingleBlockWhenUnderLimit() {
        let text = "[0:00] Speaker 1: short"
        #expect(SummaryService.splitTranscript(text, maxChars: 100) == [text])
    }

    @Test func splitTranscriptNeverCutsALine() {
        let lines = (0..<50).map { "[0:\(String(format: "%02d", $0))] Speaker 1: line number \($0)" }
        let text = lines.joined(separator: "\n")
        let blocks = SummaryService.splitTranscript(text, maxChars: 200)

        #expect(blocks.count > 1)
        for block in blocks {
            #expect(block.count <= 200)
            for line in block.split(separator: "\n") {
                #expect(lines.contains(String(line)))
            }
        }
    }

    @Test func splitTranscriptBlocksReassembleToOriginal() {
        let lines = (0..<100).map { "[0:\(String(format: "%02d", $0 % 60))] Speaker \($0 % 3): something said here \($0)" }
        let text = lines.joined(separator: "\n")
        let blocks = SummaryService.splitTranscript(text, maxChars: 500)
        #expect(blocks.joined(separator: "\n") == text)
    }

    @Test func splitTranscriptPreservesEmptyLines() {
        let text = String(repeating: "line\n\n", count: 30).trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = SummaryService.splitTranscript(text, maxChars: 40)
        #expect(blocks.joined(separator: "\n") == text)
    }

    @Test func splitTranscriptKeepsOversizedLineWhole() {
        let long = String(repeating: "x", count: 300)
        let text = "short\n\(long)\nshort"
        let blocks = SummaryService.splitTranscript(text, maxChars: 100)
        #expect(blocks.contains(long))
        #expect(blocks.joined(separator: "\n") == text)
    }

    // MARK: - markdownText (map-stage notes rendering)

    @Test func markdownTextRendersTitlesBodiesAndItems() {
        let sections = [
            SummarySection(title: "Decisions", body: "We agreed.", items: ["ship it"]),
            SummarySection(title: "Open Questions", items: ["budget?", "timeline?"])
        ]
        let text = SummaryService.markdownText(from: sections)
        #expect(text == "## Decisions\nWe agreed.\n- ship it\n\n## Open Questions\n- budget?\n- timeline?")
    }

    @Test func markdownTextSkipsEmptyParts() {
        let sections = [SummarySection(title: "Only Title")]
        #expect(SummaryService.markdownText(from: sections) == "## Only Title")
    }
}

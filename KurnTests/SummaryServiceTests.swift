//
//  SummaryServiceTests.swift
//  KurnTests
//

import Testing
@testable import Kurn

struct SummaryServiceTests {

    @Test func assembleTranscriptTextFormatsTimestampSpeakerAndText() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 5, text: "Hello"),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 65, endTime: 70, text: "Hi there")
        ]
        let text = SummaryService.assembleTranscriptText(from: [segments])
        #expect(text == "[0:00] Speaker 1: Hello\n[1:05] Speaker 2: Hi there")
    }

    @Test func assembleTranscriptTextFlattensMultipleGroupsInOrder() {
        let groupOne = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "first")]
        let groupTwo = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: "second")]
        let text = SummaryService.assembleTranscriptText(from: [groupOne, groupTwo])
        #expect(text == "[0:00] Speaker 1: first\n[0:00] Speaker 1: second")
    }

    @Test func assembleTranscriptTextIsEmptyForNoSegments() {
        #expect(SummaryService.assembleTranscriptText(from: []).isEmpty)
        #expect(SummaryService.assembleTranscriptText(from: [[]]).isEmpty)
    }

    @Test func assembleTranscriptTextUsesHourClockForLongMeetings() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 3725, endTime: 3730, text: "still going")
        ]
        let text = SummaryService.assembleTranscriptText(from: [segments])
        #expect(text == "[1:02:05] Speaker 1: still going")
    }

    @Test func assembleTranscriptTextKeepsEmptyTextSegments() {
        let segments = [
            TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: ""),
            TranscriptSegment(speakerLabel: "Speaker 2", startTime: 1, endTime: 2, text: "hi")
        ]
        let text = SummaryService.assembleTranscriptText(from: [segments])
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
}

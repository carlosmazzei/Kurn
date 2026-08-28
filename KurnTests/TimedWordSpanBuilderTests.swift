import Foundation
import KurnCore
import Testing
@testable import Kurn

struct TimedWordSpanBuilderTests {
    @Test func createsFineGrainedSpansForDiarization() {
        let spans = TimedWordSpanBuilder.spans(
            from: [
                TimedWord(text: "Olá", start: 0.1, end: 0.4),
                TimedWord(text: "mundo", start: 0.5, end: 0.9)
            ],
            fallbackText: "Olá mundo",
            duration: 1
        )

        #expect(spans.count == 2)
        #expect(spans[0].text == "Olá")
        #expect(spans[0].start == 0.1)
        #expect(spans[1].text == "mundo")
        #expect(spans[1].end == 0.9)
    }

    @Test func clampsTimingsToTheAudioDuration() {
        let spans = TimedWordSpanBuilder.spans(
            from: [TimedWord(text: "final", start: -0.2, end: 3)],
            fallbackText: "final",
            duration: 2
        )

        #expect(spans == [
            TranscribedSpan(text: "final", start: 0, end: 2, confidence: nil)
        ])
    }

    @Test func fallsBackWhenWordTimingsAreUnavailable() {
        let spans = TimedWordSpanBuilder.spans(
            from: [],
            fallbackText: "Transcrição completa",
            duration: 4.5
        )

        #expect(spans == [
            TranscribedSpan(
                text: "Transcrição completa",
                start: 0,
                end: 4.5,
                confidence: nil
            )
        ])
    }
}

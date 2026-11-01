import Foundation
import Testing
@testable import KurnCore

struct NemotronDiarizationTimelineTests {
    @Test func arrivalOrderLabelsDoNotAssumeSlotOrder() throws {
        let turns = try map(frames: frames(30, active: [7]) + frames(20, active: []) + frames(40, active: [2]))
        #expect(turns == [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0.3),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 0.5, end: 0.9)
        ])
    }

    @Test func preservesSilenceAndRepeatedSpeakerIdentity() throws {
        let turns = try map(frames: frames(20, active: []) + frames(30, active: [4])
            + frames(20, active: []) + frames(30, active: [4]) + frames(20, active: []))
        #expect(turns == [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0.2, end: 0.5),
            SpeakerTurn(speakerLabel: "Speaker 1", start: 70 * NemotronDiarizationPolicy.frameSeconds, end: 1)
        ])
    }

    @Test func preservesOverlappingSpeechWithDeterministicTies() throws {
        let turns = try map(frames: frames(20, active: [1, 6]) + frames(10, active: [1]))
        #expect(turns == [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0.3),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 0, end: 0.2)
        ])
    }

    @Test func supportsExactlyEightSpeakerSlots() throws {
        let turns = try map(frames: frames(20, active: Set(0..<8)))
        #expect(turns.count == 8)
        #expect(turns.map(\.speakerLabel) == (1...8).map { "Speaker \($0)" })
        #expect(turns.allSatisfy { $0.start == 0 && $0.end == 0.2 })
    }

    @Test func clampsPaddedTailWithoutStretchingTheSourceTimeline() throws {
        let turns = try map(frames: frames(30, active: [0]) + frames(30, active: [3]), duration: 0.555)
        #expect(turns == [
            SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0.3),
            SpeakerTurn(speakerLabel: "Speaker 2", start: 0.3, end: 0.555)
        ])
    }

    @Test func ignoresPredictionsAfterSourceEndAndClampedShortBlips() throws {
        let turns = try map(frames: frames(30, active: [0]) + frames(30, active: [3]), duration: 0.4)
        #expect(turns == [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0.3)])
        #expect(try map(frames: frames(30, active: []) + frames(30, active: [3]), duration: 0.2).isEmpty)
    }

    @Test func removesShortActivityAndKeepsTheTwoHundredMillisecondBoundary() throws {
        let turns = try map(frames: frames(19, active: [0]) + frames(1, active: []) + frames(20, active: [7]))
        #expect(turns == [SpeakerTurn(speakerLabel: "Speaker 1", start: 0.2, end: 0.4)])
    }

    @Test func validatesProbabilitiesBeforeTreatingThemAsSpeech() throws {
        let invalid: [Float] = [.nan, .infinity, -.infinity, -1, 1.01, 0.49]
        for probability in invalid {
            var values = frames(20, active: [])
            for frame in 0..<20 { values[frame * 8] = probability }
            #expect(try map(frames: values).isEmpty)
        }
        var boundary = frames(20, active: [])
        for frame in 0..<20 { boundary[frame * 8] = 0.5 }
        #expect(try map(frames: boundary).count == 1)
    }

    @Test func malformedShapesThrowWithoutChangingAccumulatedState() throws {
        var timeline = NemotronDiarizationTimeline()
        try timeline.append(probabilities: frames(20, active: [0]), frameCount: 20)
        for (probabilities, count) in [([Float](), -1), ([Float](), Int.max), ([Float](repeating: 0, count: 7), 1),
                                       ([Float](repeating: 0, count: 9), 1), ([Float](repeating: 0, count: 8), 0)] {
            #expect(throws: NemotronDiarizationTimeline.Failure.invalidProbabilityShape) {
                try timeline.append(probabilities: probabilities, frameCount: count)
            }
        }
        #expect(timeline.turns(sourceDuration: 1) == [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 0.2)])
    }

    @Test func emptySilentAndInvalidDurationInputsYieldNoTurns() throws {
        #expect(try map(frames: []).isEmpty)
        #expect(try map(frames: frames(50, active: [])).isEmpty)
        for duration: Double in [0, -1, .nan, .infinity, -.infinity] {
            #expect(try map(frames: frames(30, active: [0]), duration: duration).isEmpty)
        }
    }

    @Test func streamingChunksProduceTheSameTimelineAsACompleteBuffer() throws {
        let values = frames(15, active: [5]) + frames(15, active: [5, 2])
            + frames(20, active: [2]) + frames(10, active: []) + frames(20, active: [5])
        let expected = try map(frames: values)
        var timeline = NemotronDiarizationTimeline()
        for start in stride(from: 0, to: 80, by: 7) {
            let end = min(start + 7, 80)
            try timeline.append(probabilities: Array(values[(start * 8)..<(end * 8)]), frameCount: end - start)
        }
        #expect(timeline.turns(sourceDuration: 0.8) == expected)
        #expect(timeline.turns(sourceDuration: 0.8) == expected)
        try timeline.append(probabilities: [], frameCount: 0)
        #expect(timeline.turns(sourceDuration: 0.8) == expected)
    }

    private func frames(_ count: Int, active: Set<Int>) -> [Float] {
        (0..<count).flatMap { _ in (0..<8).map { active.contains($0) ? Float(1) : Float(0) } }
    }

    private func map(frames: [Float], duration: Double? = nil) throws -> [SpeakerTurn] {
        try NemotronDiarizationTimeline.turns(
            probabilities: frames,
            frameCount: frames.count / 8,
            sourceDuration: duration ?? Double(frames.count / 8) * 0.01
        )
    }
}

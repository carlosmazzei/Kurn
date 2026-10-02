//
//  DiarizationFinalizationTests.swift
//  KurnTests
//
//  What happens to the neural diarizer's turns once the model has run: the
//  collapse rescue only when the clustering reported one speaker, smoothing
//  always, voiceprints last, and a degraded fallback for an empty result.
//  These used to live inside `FluidAudioDiarizer`, which needs downloaded
//  models, so none of it ran in CI.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct DiarizationFinalizationTests {

    private static let windowDuration: TimeInterval = 1.5

    /// `count` windows alternating between `voices` orthogonal embeddings.
    private static func windows(voices: Int, count: Int) -> [SpeakerEmbeddingWindow] {
        (0..<count).map { index in
            let voice = index % voices
            let start = Double(index) * windowDuration
            return SpeakerEmbeddingWindow(
                start: start,
                end: start + windowDuration,
                embedding: (0..<16).map { $0 % voices == voice ? Float(1) : Float(0) }
            )
        }
    }

    /// One turn per window, labeled by `label(index)`.
    private static func turns(count: Int, label: (Int) -> String) -> [SpeakerTurn] {
        (0..<count).map { index in
            let start = Double(index) * windowDuration
            return SpeakerTurn(speakerLabel: label(index), start: start, end: start + windowDuration)
        }
    }

    @Test func aCollapsedClusteringIsRescuedFromTheEmbeddings() {
        let outcome = DiarizationFinalization.outcome(
            turns: Self.turns(count: 40) { _ in "Speaker 1" },
            distinctSpeakers: 1,
            windows: Self.windows(voices: 2, count: 40)
        )
        #expect(Set(outcome.turns.map(\.speakerLabel)).count == 2)
        #expect(outcome.voiceprints.count == 2)
        #expect(outcome.degradation == nil)
    }

    @Test func aGenuineSingleVoiceStaysOneSpeakerAndIsSmoothed() {
        let outcome = DiarizationFinalization.outcome(
            turns: Self.turns(count: 40) { _ in "Speaker 1" },
            distinctSpeakers: 1,
            windows: Self.windows(voices: 1, count: 40)
        )
        #expect(outcome.turns.count == 1, "back-to-back turns of one speaker merge")
        #expect(outcome.turns.first?.end == 60)
        #expect(Array(outcome.voiceprints.keys) == ["Speaker 1"])
    }

    @Test func severalSpeakersAreNotReclustered() {
        // The windows say one voice, but the clustering already found two: the
        // rescue only runs on a collapse, so the labels are kept.
        let outcome = DiarizationFinalization.outcome(
            turns: Self.turns(count: 20) { $0 < 10 ? "Speaker 1" : "Speaker 2" },
            distinctSpeakers: 2,
            windows: Self.windows(voices: 1, count: 20)
        )
        #expect(outcome.turns.map(\.speakerLabel) == ["Speaker 1", "Speaker 2"])
        #expect(outcome.voiceprints.count == 2)
    }

    @Test func withoutEmbeddingsThereAreNoVoiceprintsAndNoRescue() {
        let outcome = DiarizationFinalization.outcome(
            turns: Self.turns(count: 4) { _ in "Speaker 1" },
            distinctSpeakers: 1,
            windows: nil
        )
        #expect(outcome.voiceprints.isEmpty)
        #expect(outcome.turns == [SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 6)])
    }

    @Test func anEmptyResultBecomesADegradedWholeClipTurn() {
        let fallback = SpeakerTurn(speakerLabel: "Speaker 1", start: 0, end: 90)
        let empty = DiarizationFinalization.nonEmpty(DiarizationOutcome(turns: []), fallback: fallback)
        #expect(empty.turns == [fallback])
        #expect(empty.degradation == .noInput)

        let real = DiarizationOutcome(turns: [SpeakerTurn(speakerLabel: "Speaker 2", start: 1, end: 2)])
        #expect(DiarizationFinalization.nonEmpty(real, fallback: fallback).turns == real.turns)
    }

    @Test func processingBudgetScalesWithTheRecordingWithinBounds() {
        #expect(FluidAudioDiarizer.processTimeout(forAudioDuration: 0) == 180)
        #expect(FluidAudioDiarizer.processTimeout(forAudioDuration: 1_200) == 600)
        #expect(FluidAudioDiarizer.processTimeout(forAudioDuration: 36_000) == 1_800)
    }
}

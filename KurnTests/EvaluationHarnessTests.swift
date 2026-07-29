//
//  EvaluationHarnessTests.swift
//  KurnTests
//
//  Scores this app's output against annotated recordings, when there are any.
//
//  Everything here is skipped unless `KURN_EVAL_DATA` points at a directory —
//  see `EvaluationDataset` for why the material cannot live in the repository.
//  The skip is the honest default: a green CI run proves the metrics are
//  correct, never that the pipeline is accurate on real speech.
//
//  Deliberately no pass/fail threshold. A WER budget invented here would be a
//  number with no provenance, and the first time it failed the temptation would
//  be to raise it. What the harness asserts is that every declared pair was
//  actually scoreable — an unreadable or empty reference is a broken corpus, and
//  silently reporting 0% for it would be worse than not running at all. The
//  rates themselves are printed, to be compared against the previous run.
//

import Foundation
import Testing
@testable import Kurn

@Suite(.enabled(if: EvaluationDataset.isAvailable))
struct EvaluationHarnessTests {

    @Test func reportsWordErrorRate() throws {
        let pairs = try EvaluationDataset.pairs(suffix: ".txt")
        try #require(!pairs.isEmpty, "No .reference.txt/.hypothesis.txt pairs in \(EvaluationDataset.directoryVariable)")

        var totalErrors = 0
        var totalReference = 0
        for pair in pairs {
            let result = WordErrorRate.compare(reference: pair.reference, hypothesis: pair.hypothesis)
            // An empty reference makes the rate meaningless rather than perfect.
            #expect(result.referenceCount > 0, "\(pair.name): reference has no words")
            print("[eval] \(pair.name): \(result.summary)")
            totalErrors += result.errors
            totalReference += result.referenceCount
        }

        // Corpus-level rate, which is what to track between runs — averaging
        // per-file rates would weight a 30-second clip like an hour-long meeting.
        let corpus = totalReference > 0 ? Double(totalErrors) / Double(totalReference) : 0
        print(String(format: "[eval] WER over %d file(s): %.2f%%", pairs.count, corpus * 100))
    }

    @Test func reportsDiarizationErrorRate() throws {
        let pairs = try EvaluationDataset.pairs(suffix: ".rttm")
        try #require(!pairs.isEmpty, "No .reference.rttm/.hypothesis.rttm pairs in \(EvaluationDataset.directoryVariable)")

        var totalErrors: TimeInterval = 0
        var totalSpeech: TimeInterval = 0
        for pair in pairs {
            let reference = RTTM.parse(pair.reference)
            let hypothesis = RTTM.parse(pair.hypothesis)
            #expect(!reference.isEmpty, "\(pair.name): reference RTTM has no SPEAKER turns")

            let result = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis)
            print("[eval] \(pair.name): \(result.summary)")
            print("[eval] \(pair.name): mapping \(result.mapping.sorted { $0.key < $1.key })")
            totalErrors += result.errors
            totalSpeech += result.referenceSpeech
        }

        let corpus = totalSpeech > 0 ? totalErrors / totalSpeech : 0
        print(String(format: "[eval] DER over %d file(s): %.2f%%", pairs.count, corpus * 100))
    }

    /// The same score, but with the hypothesis produced *here* by running the
    /// app's own diarizer over the audio, instead of pasted in by hand.
    ///
    /// This is the one that can catch a regression, because it re-derives the
    /// result every run. It uses the heuristic engine deliberately: it needs no
    /// download and no network, so it is the only one that can run unattended —
    /// and it is also the engine whose accuracy this repository has never
    /// actually measured, only asserted against synthetic tones.
    @Test func scoresTheHeuristicDiarizerAgainstAnnotatedAudio() async throws {
        let annotated = try EvaluationDataset.audioWithReferenceRTTM()
        try #require(
            !annotated.isEmpty,
            "No <name>.reference.rttm with matching audio in \(EvaluationDataset.directoryVariable)"
        )

        var totalErrors: TimeInterval = 0
        var totalSpeech: TimeInterval = 0
        for item in annotated {
            let reference = RTTM.parse(item.reference)
            #expect(!reference.isEmpty, "\(item.name): reference RTTM has no SPEAKER turns")

            let turns = await SpeakerDiarizer().diarize(url: item.audio)
            let hypothesis = turns.map {
                DiarizationErrorRate.Segment(label: $0.speakerLabel, start: $0.start, end: $0.end)
            }
            let result = DiarizationErrorRate.compare(reference: reference, hypothesis: hypothesis)
            print("[eval] \(item.name) (heuristic): \(result.summary)")
            print("[eval] \(item.name): reference speakers \(Set(reference.map(\.label)).count), found \(Set(turns.map(\.speakerLabel)).count)")
            totalErrors += result.errors
            totalSpeech += result.referenceSpeech
        }

        let corpus = totalSpeech > 0 ? totalErrors / totalSpeech : 0
        print(String(format: "[eval] heuristic DER over %d file(s): %.2f%%", annotated.count, corpus * 100))
    }
}

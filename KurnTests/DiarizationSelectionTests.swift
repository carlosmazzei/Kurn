//
//  DiarizationSelectionTests.swift
//  KurnTests
//
//  Which diarizer actually runs.
//
//  The default is `.fluidAudio`, but it downloads its models on first use, and
//  two things must never happen: a download for a feature the user has not opted
//  into, and a silent degradation to one turn for the whole meeting when that
//  download is not there. The pair (choice, consent) is what decides, and it is
//  pure — so it is tested here rather than inferred from a pipeline run.
//

import Foundation
import Testing
@testable import Kurn

struct DiarizationSelectionTests {

    @Test func theDefaultIsTheNeuralEngine() {
        #expect(PipelineConfiguration().diarization == .fluidAudio)
    }

    /// Without consent the neural engine is not run and, critically, not
    /// downloaded either — the fallback is the point.
    @Test func withoutConsentItFallsBackToTheHeuristic() {
        let config = PipelineConfiguration(diarization: .fluidAudio, diarizationConsented: false)
        #expect(config.effectiveDiarization == .heuristic)
        #expect(config.diarizationFellBack)
    }

    @Test func withConsentTheNeuralEngineRuns() {
        let config = PipelineConfiguration(diarization: .fluidAudio, diarizationConsented: true)
        #expect(config.effectiveDiarization == .fluidAudio)
        #expect(!config.diarizationFellBack)
    }

    /// Choosing the heuristic engine explicitly is a choice, not a fallback, and
    /// must not raise a warning telling the user to download anything.
    @Test func choosingTheHeuristicIsNotAFallback() {
        for consented in [true, false] {
            let config = PipelineConfiguration(diarization: .heuristic, diarizationConsented: consented)
            #expect(config.effectiveDiarization == .heuristic)
            #expect(!config.diarizationFellBack)
        }
    }
}

//
//  KnowledgeAskFailureTests.swift
//  KurnCoreTests
//
//  The K7.0 failure taxonomy: a failed Ask answer is blamed on the layer furthest
//  upstream that explains it, and the ranked counts order the K7 steps.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeAskFailureTests {
    private static let expectation = KnowledgeAnswerScorer.Expectation(
        expected: ["a1", "a2"], forbidden: [], mustRefuse: false, citable: ["m1/s1", "m2/s2"]
    )

    private static func score(stated: Set<String>) -> KnowledgeAnswerScorer.Score {
        KnowledgeAnswerScorer.score(.init(stated: stated, refused: false, cited: ["m1/s1"]),
                                    against: expectation, resolvable: ["m1/s1", "m2/s2"])
    }

    private static func diagnosis(compiled: Set<String> = ["a1", "a2"], connected: Bool = true,
                                  retrieved: Set<String> = ["a1", "a2"], clock: Bool = false)
        -> KnowledgeAskFailureClassifier.Diagnosis {
        .init(compiled: compiled, connected: connected, retrieved: retrieved, clockMismatch: clock)
    }

    private static func classify(_ diagnosis: KnowledgeAskFailureClassifier.Diagnosis,
                                 stated: Set<String> = ["a1"]) -> KnowledgeAskFailureClass? {
        KnowledgeAskFailureClassifier.classify(score(stated: stated), expectation: expectation, diagnosis: diagnosis)
    }

    @Test func aCorrectAnswerIsNotAFailure() {
        #expect(Self.classify(Self.diagnosis(), stated: ["a1", "a2"]) == nil)
    }

    @Test func aMissingCompiledFactIsAnExtractionFailureEvenWhenEverythingElseIsWrong() {
        let diagnosis = Self.diagnosis(compiled: ["a1"], connected: false, retrieved: [], clock: true)
        #expect(Self.classify(diagnosis) == .extraction)
    }

    @Test func compiledButDisconnectedFactsAreAnIsland() {
        #expect(Self.classify(Self.diagnosis(connected: false, retrieved: ["a1"])) == .island)
        // One expected assertion cannot be split from itself.
        let single = KnowledgeAnswerScorer.Expectation(expected: ["a1"], forbidden: [], mustRefuse: false, citable: [])
        let missed = KnowledgeAnswerScorer.score(.init(stated: [], refused: false, cited: []), against: single, resolvable: [])
        let classified = KnowledgeAskFailureClassifier.classify(
            missed, expectation: single,
            diagnosis: .init(compiled: ["a1"], connected: false, retrieved: [], clockMismatch: false))
        #expect(classified == .lostHop)
    }

    @Test func aClockMixUpOutranksALostHop() {
        #expect(Self.classify(Self.diagnosis(retrieved: ["a1"], clock: true)) == .temporal)
    }

    @Test func connectedFactsTheRunNeverSurfacedAreALostHop() {
        #expect(Self.classify(Self.diagnosis(retrieved: ["a1"])) == .lostHop)
    }

    @Test func surfacedFactsStatedWrongAreTemporal() {
        #expect(Self.classify(Self.diagnosis()) == .temporal)
    }

    @Test func rankingPutsTheDominantClassFirstAndOmitsTheAbsent() {
        let ranked = KnowledgeAskFailureClassifier.ranked([.lostHop, .island, .lostHop, .lostHop, .island])
        #expect(ranked.map { $0.failure } == [.lostHop, .island])
        #expect(ranked.map { $0.count } == [3, 2])
        #expect(KnowledgeAskFailureClassifier.ranked([]).isEmpty)
        let tie = KnowledgeAskFailureClassifier.ranked([.temporal, .island])
        #expect(tie.map { $0.failure } == [.island, .temporal])
    }

    @Test func everyClassNamesItsRemedy() {
        #expect(KnowledgeAskFailureClass.allCases.allSatisfy { !$0.remedy.isEmpty })
        #expect(Set(KnowledgeAskFailureClass.allCases.map(\.rawValue)) == ["extraction", "island", "lostHop", "temporal"])
    }
}

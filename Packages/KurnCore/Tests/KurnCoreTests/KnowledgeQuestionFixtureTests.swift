//
//  KnowledgeQuestionFixtureTests.swift
//  KurnCoreTests
//
//  The synthetic Ask question set (`Fixtures/knowledge-questions/`, format
//  `kurn.knowledge-questions` v1) over the knowledge golden set: per question,
//  the assertions a correct answer states, the tempting `mustNotAssert` ones it
//  must not, whether it must decline and the segments it may cite. These tests
//  keep the set honest against its fixtures and pin `KnowledgeAnswerScorer`'s
//  baselines: an oracle answer scores perfectly, a decline-everything one does not.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeQuestionSet: Decodable {
    struct Question: Decodable {
        let id: String
        let fixture: String
        let language: String
        let kind: String
        let question: String
        let expected: [String]
        let forbidden: [Int]
        let mustRefuse: Bool
        let citable: [String]

        var expectation: KnowledgeAnswerScorer.Expectation {
            .init(expected: Set(expected), forbidden: Set(forbidden.map { "!\($0)" }), mustRefuse: mustRefuse, citable: Set(citable))
        }
    }

    let format: String
    let version: Int
    let summary: String
    let questions: [Question]
}

struct KnowledgeQuestionFixtureTests {
    private static let kinds: Set = ["fact", "temporal", "absence", "injection", "correction"]

    private static func questions() throws -> KnowledgeQuestionSet {
        let url = try #require(Bundle.module.url(forResource: "questions", withExtension: "json",
                                                 subdirectory: "Fixtures/knowledge-questions"))
        return try JSONDecoder().decode(KnowledgeQuestionSet.self, from: Data(contentsOf: url))
    }

    private static func fixture(_ name: String) throws -> KnowledgeFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/knowledge"))
        return try JSONDecoder().decode(KnowledgeFixture.self, from: Data(contentsOf: url))
    }

    private static func segments(_ fixture: KnowledgeFixture) -> Set<String> {
        Set(fixture.sources.flatMap { source in source.segments.map { "\(source.id)/\($0.id)" } })
    }

    @Test func theSetIsWellFormedAndCoversEveryKindInBothLanguages() throws {
        let set = try Self.questions()
        #expect(set.format == "kurn.knowledge-questions" && set.version == 1 && set.summary.hasPrefix("Synthetic."))
        #expect(Set(set.questions.map(\.id)).count == set.questions.count)
        #expect(Set(set.questions.map(\.kind)) == Self.kinds)
        #expect(Set(set.questions.map(\.language)) == KnowledgeFixtureVocabulary.languages)
        #expect(Set(set.questions.map(\.fixture)) == Set(KnowledgeFixtureVocabulary.files))
        #expect(set.questions.contains { $0.mustRefuse } && set.questions.contains { !$0.mustRefuse })
    }

    @Test func everyReferenceResolvesInItsFixture() throws {
        for question in try Self.questions().questions {
            let fixture = try Self.fixture(question.fixture)
            let segments = Self.segments(fixture)
            #expect(question.language == fixture.language, "\(question.id)")
            #expect(!question.question.isEmpty, "\(question.id)")
            let assertions = Dictionary(uniqueKeysWithValues: fixture.expected.assertions.map { ($0.ref, $0) })
            #expect(Set(question.expected).isSubset(of: Set(assertions.keys)), "\(question.id)")
            #expect(question.forbidden.allSatisfy { fixture.expected.mustNotAssert.indices.contains($0) }, "\(question.id)")
            #expect(Set(question.citable).isSubset(of: segments), "\(question.id)")
            // A correct answer can cite the evidence of everything it must state.
            let evidence = question.expected.compactMap { assertions[$0] }.flatMap(\.evidence)
                .flatMap { item in item.segmentIDs.map { "\(item.source)/\($0)" } }
            #expect(Set(evidence).isSubset(of: Set(question.citable)), "\(question.id)")
            #expect(question.mustRefuse || !question.expected.isEmpty, "\(question.id)")
        }
    }

    @Test func anOracleAnswerScoresPerfectly() throws {
        let set = try Self.questions()
        var scores: [KnowledgeAnswerScorer.Score] = []
        for question in set.questions {
            let oracle = KnowledgeAnswerScorer.Observation(stated: Set(question.expected), refused: question.mustRefuse,
                                                           cited: Set(question.citable))
            scores.append(KnowledgeAnswerScorer.score(oracle, against: question.expectation,
                                                      resolvable: Self.segments(try Self.fixture(question.fixture))))
        }
        let summary = KnowledgeAnswerScorer.summary(scores)
        #expect(summary == .init(questions: set.questions.count, precision: 1, recall: 1, forbiddenStated: 0,
                                 refusalsHonoured: 1, citationsResolvable: 1, citationsGrounded: 1))
    }

    @Test func declineEverythingIsABaselineNotAPass() throws {
        let set = try Self.questions()
        let scores = set.questions.map {
            KnowledgeAnswerScorer.score(.init(stated: [], refused: true, cited: []), against: $0.expectation, resolvable: [])
        }
        let summary = KnowledgeAnswerScorer.summary(scores)
        #expect(summary.precision == 1 && summary.recall < 1 && summary.refusalsHonoured < 1)
    }

    @Test func statingATemptingClaimOrCitingAMissingSegmentIsPenalised() {
        let expectation = KnowledgeAnswerScorer.Expectation(expected: ["a1"], forbidden: ["!0"], mustRefuse: false, citable: ["m1/s1"])
        let score = KnowledgeAnswerScorer.score(.init(stated: ["a1", "!0"], refused: false, cited: ["m1/s1", "m9/s9"]),
                                                against: expectation, resolvable: ["m1/s1"])
        #expect(score == .init(precision: 0.5, recall: 1, forbiddenStated: 1, refusalHonoured: true, citationsResolvable: false,
                               citationsGrounded: false))
        // A real segment unrelated to the question, or no citation at all, is not grounding.
        let unrelated = KnowledgeAnswerScorer.score(.init(stated: ["a1"], refused: false, cited: ["m1/s2"]),
                                                    against: expectation, resolvable: ["m1/s1", "m1/s2"])
        #expect(unrelated.citationsResolvable && !unrelated.citationsGrounded)
        #expect(!KnowledgeAnswerScorer.score(.init(stated: ["a1"], refused: false, cited: []), against: expectation,
                                             resolvable: ["m1/s1"]).citationsGrounded)
        #expect(KnowledgeAnswerScorer.summary([]).questions == 0)
    }
}

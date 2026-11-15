//
//  KnowledgeTypesTests.swift
//  KurnCoreTests
//
//  The canonical layer's closed vocabularies, temporal values at their stated
//  precision, typed values, the predicate registry and the evidence validator.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeTemporalValueTests {
    @Test func parsesEachPrecisionAndRoundTrips() throws {
        let month = try #require(KnowledgeTemporalValue(text: "2026-10", precision: .month))
        #expect(month.year == 2026 && month.month == 10 && month.day == nil && month.text == "2026-10")
        let day = try #require(KnowledgeTemporalValue(text: "2026-11-05", precision: .day))
        #expect(day.day == 5 && day.secondOfDay == nil && day.text == "2026-11-05")
        let instant = try #require(KnowledgeTemporalValue(text: "2026-11-05T09:07:03Z", precision: .instant))
        #expect(instant.secondOfDay == 9 * 3600 + 7 * 60 + 3 && instant.text == "2026-11-05T09:07:03Z")
    }

    @Test func neverInventsPrecisionOrImpossibleDates() {
        #expect(KnowledgeTemporalValue(text: "2026-10-01", precision: .month) == nil)
        #expect(KnowledgeTemporalValue(text: "2026-10", precision: .day) == nil)
        #expect(KnowledgeTemporalValue(text: "2026-02-30", precision: .day) == nil)
        #expect(KnowledgeTemporalValue(text: "2026-13", precision: .month) == nil)
        #expect(KnowledgeTemporalValue(text: "2026-11-05T24:00:00Z", precision: .instant) == nil)
        #expect(KnowledgeTemporalValue(text: "2026-11-05T10:00:00+01:00", precision: .instant) == nil)
        #expect(KnowledgeTemporalValue(text: "anything", precision: .unknown) == nil)
    }

    @Test func leapYearsFollowTheGregorianRule() {
        #expect(KnowledgeTemporalValue(text: "2028-02-29", precision: .day) != nil)
        #expect(KnowledgeTemporalValue(text: "2100-02-29", precision: .day) == nil)
        #expect(KnowledgeTemporalValue(text: "2000-02-29", precision: .day) != nil)
        #expect(KnowledgeTemporalValue(text: "2026-04-31", precision: .day) == nil)
    }
}

struct KnowledgeTypedValueTests {
    private func decode(_ json: String) throws -> KnowledgeTypedValue {
        try JSONDecoder().decode(KnowledgeTypedValue.self, from: Data(json.utf8))
    }

    @Test func decodesEveryTypeOfTheWireForm() throws {
        #expect(try decode(#"{"type":"number","value":"5","unit":"day"}"#) == .number(5, unit: "day"))
        #expect(try decode(#"{"type":"number","value":"2.5"}"#) == .number(2.5, unit: nil))
        #expect(try decode(#"{"type":"enum","value":"approved"}"#) == .enumeration("approved"))
        #expect(try decode(#"{"type":"string","value":"blue"}"#) == .string("blue"))
        #expect(try decode(#"{"type":"boolean","value":"true"}"#) == .boolean(true))
        let date = try #require(KnowledgeTemporalValue(text: "2026-10", precision: .month))
        #expect(try decode(#"{"type":"date","value":"2026-10","precision":"month"}"#) == .date(date))
    }

    @Test func rejectsValuesThatDoNotMatchTheirType() {
        for json in [
            #"{"type":"number","value":"five"}"#,
            #"{"type":"number","value":"inf"}"#,
            #"{"type":"boolean","value":"yes"}"#,
            #"{"type":"date","value":"2026-10-01","precision":"month"}"#,
            #"{"type":"date","value":"2026-10"}"#,
            #"{"type":"enum","value":"two words"}"#,
            #"{"type":"string","value":""}"#,
            #"{"type":"colour","value":"red"}"#
        ] {
            #expect(throws: (any Error).self) { try decode(json) }
        }
    }

    @Test func roundTripsThroughTheWireForm() throws {
        let date = try #require(KnowledgeTemporalValue(text: "2026-11-05", precision: .day))
        for value: KnowledgeTypedValue in [
            .number(300_000, unit: "BRL"), .number(0.25, unit: nil), .boolean(false),
            .string("x"), .enumeration("open"), .date(date)
        ] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(KnowledgeTypedValue.self, from: data) == value)
        }
        let whole = try JSONEncoder().encode(KnowledgeTypedValue.number(5, unit: nil))
        #expect(String(decoding: whole, as: UTF8.self).contains(#""value":"5""#))
    }
}

struct KnowledgePredicateRegistryTests {
    @Test func everyPredicateHasARuleAndTheVersionIsSet() {
        #expect(KnowledgePredicate.registryVersion == 1)
        for predicate in KnowledgePredicate.allCases {
            _ = predicate.rule
        }
        #expect(KnowledgePredicate.relatesTo.rule.isSymmetric && KnowledgePredicate.contradicts.rule.isSymmetric)
        #expect(!KnowledgePredicate.supersedes.rule.isSymmetric)
    }

    @Test func ownershipInfluenceAndAdoptionNeedAnExplicitStatement() {
        for predicate in [KnowledgePredicate.owns, .assignedTo, .inspiredBy, .adoptedIn] {
            #expect(predicate.rule.requiresExplicitStatement)
        }
        #expect(!KnowledgePredicate.relatesTo.rule.requiresExplicitStatement)
    }

    @Test func checksSubjectsObjectsAndValues() {
        let assigned = KnowledgePredicate.assignedTo.rule
        #expect(assigned.violation(subjectKind: .actionItem, objectKind: .person, valueType: nil) == nil)
        #expect(assigned.violation(subjectKind: .topic, objectKind: .person, valueType: nil) == .subjectKindNotAllowed)
        #expect(assigned.violation(subjectKind: .actionItem, objectKind: .topic, valueType: nil) == .objectKindNotAllowed)
        #expect(assigned.violation(subjectKind: .actionItem, objectKind: nil, valueType: .string) == .valueWhereEntityExpected)
        #expect(assigned.violation(subjectKind: .actionItem, objectKind: nil, valueType: nil) == .missingObject)

        let status = KnowledgePredicate.hasStatus.rule
        #expect(status.violation(subjectKind: .project, objectKind: nil, valueType: .enumeration) == nil)
        #expect(status.violation(subjectKind: .project, objectKind: nil, valueType: .number) == .valueTypeNotAllowed)
        #expect(status.violation(subjectKind: .project, objectKind: .team, valueType: nil) == .entityWhereValueExpected)
        #expect(status.violation(subjectKind: .project, objectKind: nil, valueType: nil) == .missingObject)

        #expect(KnowledgePredicate.forecastFor.rule.violation(subjectKind: .topic, objectKind: .topic, valueType: nil) == .subjectKindNotAllowed)
        #expect(KnowledgePredicate.dueOn.rule.violation(subjectKind: .person, objectKind: nil, valueType: .date) == .subjectKindNotAllowed)
        #expect(KnowledgePredicate.resolves.rule.violation(subjectKind: .person, objectKind: .question, valueType: nil) == nil)
    }

    @Test func violationCodesAreStableSnakeCase() {
        for violation in KnowledgeSchemaViolation.allCases {
            #expect(violation.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
        }
    }
}

struct KnowledgeVocabularyTests {
    @Test func reviewStatesThatHideAnAssertion() {
        #expect(KnowledgeReviewState.allCases.filter { !$0.isVisible } == [.rejected, .invalidated])
    }

    @Test func externalClaimKindsAreTheOutsideVoices() {
        #expect(Set(KnowledgeClaimKind.allCases.filter(\.isExternal))
            == [.analystForecast, .vendorClaim, .externalObservation, .researchFinding])
        #expect(!KnowledgeClaimKind.internalDecision.isExternal)
    }

    @Test func actorsAreThePeopleAndBodiesThatAct() {
        #expect(KnowledgeEntityKind.actors == [.person, .team, .organization])
    }

    @Test func rawValuesAreThePersistedVocabulary() throws {
        #expect(KnowledgeEntityKind.decisionThread.rawValue == "decisionThread")
        #expect(KnowledgeValueType.enumeration.rawValue == "enum")
        #expect(KnowledgeContextKind.allCases.count == 10)
        #expect(KnowledgeOrganizationRole.allCases.count == 7)
        #expect(KnowledgeAuthorityStatus.allCases.count == 6)
        #expect(KnowledgeConfidenceBand.allCases == [.low, .medium, .high])
        #expect(KnowledgeModality.allCases.count == 7 && KnowledgePolarity.allCases.count == 2)
    }
}

struct KnowledgeEvidenceValidatorTests {
    private let validator = KnowledgeEvidenceValidator(segments: [
        KnowledgeSourceSegment(id: "s1", startMs: 0, endMs: 5000, text: "We’re not   migrating\nthis quarter."),
        KnowledgeSourceSegment(id: "s2", startMs: 5500, endMs: 9000, text: "Alex owns the runbook.")
    ])

    @Test func acceptsAVerbatimQuoteUnderConservativeNormalization() throws {
        let result = try validator.validate(KnowledgeEvidenceClaim(segmentIDs: ["s1"], quote: "We're not migrating this quarter.")).get()
        #expect(result.startMs == 0 && result.endMs == 5000)
        #expect(result.normalizedQuote == "We're not migrating this quarter.")
    }

    @Test func acceptsAQuoteSpanningCitedSegmentsWithinTheirTime() throws {
        let claim = KnowledgeEvidenceClaim(segmentIDs: ["s1", "s2"], quote: "this quarter. Alex owns", startMs: 4000, endMs: 6000)
        let result = try validator.validate(claim).get()
        #expect(result.segmentIDs == ["s1", "s2"] && result.startMs == 4000 && result.endMs == 6000)
    }

    @Test func rejectsWhatIsNotWhatWasSaid() {
        let cases: [(KnowledgeEvidenceClaim, KnowledgeEvidenceRejection)] = [
            (KnowledgeEvidenceClaim(segmentIDs: [], quote: "x"), .noSegments),
            (KnowledgeEvidenceClaim(segmentIDs: ["s9"], quote: "x"), .unknownSegment),
            (KnowledgeEvidenceClaim(segmentIDs: ["s1", "s1"], quote: "We"), .repeatedSegment),
            (KnowledgeEvidenceClaim(segmentIDs: ["s1"], quote: "  \n "), .emptyQuote),
            (KnowledgeEvidenceClaim(segmentIDs: ["s1"], quote: "we're not migrating"), .quoteNotVerbatim),
            (KnowledgeEvidenceClaim(segmentIDs: ["s2"], quote: "this quarter."), .quoteNotVerbatim),
            (KnowledgeEvidenceClaim(segmentIDs: ["s1"], quote: "We", startMs: 3000, endMs: 3000), .invertedTimeRange),
            (KnowledgeEvidenceClaim(segmentIDs: ["s1"], quote: "We", startMs: 4000, endMs: 6000), .timeOutsideSegments)
        ]
        for (claim, rejection) in cases {
            #expect(validator.validate(claim) == .failure(rejection))
        }
    }

    @Test func normalizationKeepsCaseDiacriticsAndPunctuation() {
        #expect(KnowledgeEvidenceValidator.normalized("  “Não”\t é  ") == "\"Não\" é")
        #expect(KnowledgeEvidenceValidator.normalized("Ação") == KnowledgeEvidenceValidator.normalized("Ac\u{0327}a\u{0303}o"))
        #expect(KnowledgeEvidenceValidator.normalized("ABC") != "abc")
    }

    @Test func rejectionCodesAreStableSnakeCase() {
        for rejection in KnowledgeEvidenceRejection.allCases {
            #expect(rejection.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
        }
    }
}

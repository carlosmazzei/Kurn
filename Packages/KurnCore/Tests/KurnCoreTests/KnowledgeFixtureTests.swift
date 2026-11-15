//
//  KnowledgeFixtureTests.swift
//  KurnCoreTests
//
//  The Knowledge Engine's synthetic golden set (`Fixtures/knowledge/`,
//  format `kurn.knowledge-fixture` v1): meetings with stable segment IDs and
//  the entities, assertions and refusals a correct extraction must produce.
//  Extraction does not exist yet, so these tests keep the set itself honest —
//  every quote is verbatim in the segments it cites, every reference resolves,
//  every value uses the spec's closed vocabularies, and the set covers each
//  hard case the specification names (negation, irony, homonyms, wrong speaker,
//  provisional decisions, relative dates, late arrival, reopening,
//  supersession, units, corrected transcripts, prompt injection, external
//  contexts, forecasts that are not decisions) in both Portuguese and English.
//  Organizations are fictional by rule: public fixtures never name a real one.
//
//  The vocabularies below are the specification's (v1.3, §5 and §20); the
//  extraction contract will move them into KurnCore and this suite will read
//  them from there.
//

import Foundation
import Testing

struct KnowledgeFixture: Decodable {
    struct Segment: Decodable {
        let id: String
        let speaker: String?
        let startMs: Int
        let endMs: Int
        let text: String
    }

    struct Source: Decodable {
        let id: String
        let context: String
        let organization: String?
        let recordedAt: String
        let ingestedAt: String
        let timezone: String
        let segments: [Segment]
        let correctedFrom: [Segment]?
    }

    struct Entity: Decodable {
        let ref: String
        let kind: String
        let name: String
        let aliases: [String]
    }

    struct Value: Decodable {
        let type: String
        let value: String
        let unit: String?
        let precision: String?
    }

    struct Evidence: Decodable {
        let source: String
        let segmentIDs: [String]
        let quote: String
    }

    struct Assertion: Decodable {
        let ref: String
        let subject: String
        let predicate: String
        let object: String?
        let value: Value?
        let modality: String
        let polarity: String
        let claimKind: String
        let validFrom: String?
        let precision: String
        let evidence: [Evidence]
    }

    struct Forbidden: Decodable {
        /// The segments that would tempt a wrong extraction into this assertion.
        let segmentIDs: [String]
        /// The tempting span, verbatim, so rewording the segment fails the suite.
        let quote: String
        let subject: String
        let predicate: String
        let object: String?
        let value: String?
        let source: String?
        let reason: String
    }

    struct Expected: Decodable {
        let entities: [Entity]
        let assertions: [Assertion]
        let mustNotAssert: [Forbidden]
        let mustNotMerge: [[String]]
    }

    let format: String
    let version: Int
    let id: String
    let language: String
    let summary: String
    let covers: [String]
    /// For each hard case the fixture covers, the segments that exhibit it.
    let caseSegments: [String: [String]]
    let sources: [Source]
    let expected: Expected
}

enum KnowledgeFixtureVocabulary {
    static let files = [
        "en-platform-review", "en-three-contexts", "pt-corrected-transcript", "pt-provisioning-timeline"
    ]
    static let languages: Set = ["en", "pt-BR"]
    static let hardCases: Set = [
        "negation", "irony", "homonyms", "wrongSpeaker", "provisionalDecision", "relativeDate", "lateArrival",
        "reopen", "supersede", "units", "correctedTranscript", "promptInjection", "externalContexts",
        "forecastNotDecision"
    ]
    static let entityKinds: Set = [
        "topic", "project", "initiative", "person", "team", "organization", "system", "technology",
        "decisionThread", "actionItem", "risk", "question", "metric"
    ]
    static let predicates: Set = [
        "relatesTo", "partOf", "owns", "assignedTo", "dependsOn", "blocks", "supports", "opposes", "proposes",
        "approves", "rejects", "supersedes", "contradicts", "resolves", "mentions", "reportsMetric", "hasStatus",
        "dueOn", "presentedAt", "hostedBy", "attributedTo", "discusses", "evaluates", "references", "inspiredBy",
        "adoptedIn", "challenges", "forecastFor"
    ]
    static let modalities: Set = ["reported", "proposed", "agreed", "disputed", "hypothetical", "observed", "inferred"]
    static let polarities: Set = ["positive", "negative"]
    static let claimKinds: Set = [
        "analystForecast", "vendorClaim", "externalObservation", "researchFinding", "personalReflection",
        "internalHypothesis", "internalProposal", "internalDecision", "internalStatusReport", "commitment",
        "question", "unknown"
    ]
    static let contexts: Set = [
        "internalMeeting", "conference", "conferenceSession", "executiveBriefing", "vendorDiscussion",
        "executiveConversation", "workshop", "personalReflection", "other", "unknown"
    ]
    static let precisions: Set = ["instant", "day", "month", "unknown"]
    static let valueTypes: Set = ["string", "number", "boolean", "date", "enum"]
}

struct KnowledgeFixtureTests {
    private static func load(_ name: String) throws -> KnowledgeFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/knowledge"))
        return try JSONDecoder().decode(KnowledgeFixture.self, from: Data(contentsOf: url))
    }

    private static func loadAll() throws -> [KnowledgeFixture] {
        try KnowledgeFixtureVocabulary.files.map(load)
    }

    private static func instant(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// Whether `text` is a calendar value written at `precision`.
    private static func matches(_ text: String, precision: String) -> Bool {
        let pattern = switch precision {
        case "day": #"^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$"#
        case "month": #"^\d{4}-(0[1-9]|1[0-2])$"#
        case "instant": #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#
        default: "^$"
        }
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    @Test func everyListedFixtureIsInTheBundleAndNothingElseIs() throws {
        let directory = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures/knowledge"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
        #expect(Set(names) == Set(KnowledgeFixtureVocabulary.files))
    }

    @Test func headersAreValidAndIDsMatchFileNames() throws {
        for name in KnowledgeFixtureVocabulary.files {
            let fixture = try Self.load(name)
            #expect(fixture.format == "kurn.knowledge-fixture")
            #expect(fixture.version == 1)
            #expect(fixture.id == name)
            #expect(KnowledgeFixtureVocabulary.languages.contains(fixture.language))
            #expect(fixture.summary.hasPrefix("Synthetic."), "\(name): the summary must say the material is synthetic")
            #expect(!fixture.covers.isEmpty && Set(fixture.covers).isSubset(of: KnowledgeFixtureVocabulary.hardCases))
        }
    }

    @Test func theSetCoversEveryHardCaseInBothLanguages() throws {
        let fixtures = try Self.loadAll()
        #expect(Set(fixtures.flatMap(\.covers)) == KnowledgeFixtureVocabulary.hardCases)
        #expect(Set(fixtures.map(\.language)) == KnowledgeFixtureVocabulary.languages)
    }

    @Test func sourcesAreWellFormed() throws {
        for fixture in try Self.loadAll() {
            #expect(Set(fixture.sources.map(\.id)).count == fixture.sources.count, "\(fixture.id): duplicate source")
            let segmentIDs = fixture.sources.flatMap { $0.segments.map(\.id) }
            #expect(Set(segmentIDs).count == segmentIDs.count, "\(fixture.id): segment IDs must be unique in a fixture")
            for source in fixture.sources {
                #expect(KnowledgeFixtureVocabulary.contexts.contains(source.context))
                #expect(TimeZone(identifier: source.timezone) != nil)
                let recorded = try #require(Self.instant(source.recordedAt))
                let ingested = try #require(Self.instant(source.ingestedAt))
                #expect(ingested >= recorded, "\(fixture.id)/\(source.id): ingested before it was recorded")
                if let organization = source.organization {
                    #expect(organization.hasPrefix("Example "), "\(fixture.id): organizations must be fictional")
                }
                #expect(!source.segments.isEmpty)
                var previousEnd = -1
                for segment in source.segments {
                    #expect(segment.startMs >= 0 && segment.startMs < segment.endMs)
                    #expect(segment.startMs >= previousEnd, "\(fixture.id)/\(segment.id): segments overlap or are out of order")
                    #expect(!segment.text.trimmingCharacters(in: .whitespaces).isEmpty)
                    previousEnd = segment.endMs
                }
            }
        }
    }

    @Test func entitiesUseTheVocabularyAndUniqueRefs() throws {
        for fixture in try Self.loadAll() {
            let refs = fixture.expected.entities.map(\.ref)
            #expect(Set(refs).count == refs.count, "\(fixture.id): duplicate entity ref")
            for entity in fixture.expected.entities {
                #expect(KnowledgeFixtureVocabulary.entityKinds.contains(entity.kind), "\(fixture.id): kind \(entity.kind)")
                #expect(!entity.name.isEmpty)
                if entity.kind == "organization" {
                    #expect(entity.name.hasPrefix("Example "), "\(fixture.id): organizations must be fictional")
                }
            }
        }
    }

    @Test func assertionsAreGroundedInVerbatimEvidence() throws {
        for fixture in try Self.loadAll() {
            let entities = Set(fixture.expected.entities.map(\.ref))
            let refs = fixture.expected.assertions.map(\.ref)
            #expect(Set(refs).count == refs.count, "\(fixture.id): duplicate assertion ref")
            let sources = Dictionary(uniqueKeysWithValues: fixture.sources.map { ($0.id, $0) })
            for assertion in fixture.expected.assertions {
                let label = "\(fixture.id)/\(assertion.ref)"
                #expect(entities.contains(assertion.subject), "\(label): unknown subject")
                #expect(KnowledgeFixtureVocabulary.predicates.contains(assertion.predicate), "\(label): predicate")
                #expect(KnowledgeFixtureVocabulary.modalities.contains(assertion.modality), "\(label): modality")
                #expect(KnowledgeFixtureVocabulary.polarities.contains(assertion.polarity), "\(label): polarity")
                #expect(KnowledgeFixtureVocabulary.claimKinds.contains(assertion.claimKind), "\(label): claim kind")
                #expect(KnowledgeFixtureVocabulary.precisions.contains(assertion.precision), "\(label): precision")
                if let validFrom = assertion.validFrom {
                    #expect(Self.matches(validFrom, precision: assertion.precision), "\(label): validFrom vs precision")
                } else {
                    #expect(assertion.precision == "unknown", "\(label): a date-less assertion has unknown precision")
                }
                #expect((assertion.object == nil) != (assertion.value == nil), "\(label): exactly one of object or value")
                if let object = assertion.object {
                    #expect(entities.contains(object), "\(label): unknown object")
                }
                if let value = assertion.value {
                    #expect(KnowledgeFixtureVocabulary.valueTypes.contains(value.type), "\(label): value type")
                    if value.type == "number" { #expect(Double(value.value) != nil, "\(label): number") }
                    if value.type == "date" {
                        let precision = try #require(value.precision, "\(label): a date value carries its precision")
                        #expect(Self.matches(value.value, precision: precision), "\(label): date vs precision")
                    }
                }
                #expect(!assertion.evidence.isEmpty, "\(label): an assertion needs evidence")
                for evidence in assertion.evidence {
                    let source = try #require(sources[evidence.source], "\(label): unknown source")
                    let segments = Dictionary(uniqueKeysWithValues: source.segments.map { ($0.id, $0) })
                    let cited = try evidence.segmentIDs.map { try #require(segments[$0], "\(label): unknown segment \($0)") }
                    let text = cited.map(\.text).joined(separator: " ")
                    #expect(!evidence.quote.isEmpty && text.contains(evidence.quote), "\(label): quote is not verbatim")
                }
            }
        }
    }

    @Test func refusalsAndSeparationsResolve() throws {
        for fixture in try Self.loadAll() {
            let entities = Dictionary(uniqueKeysWithValues: fixture.expected.entities.map { ($0.ref, $0) })
            let sources = Set(fixture.sources.map(\.id))
            let segmentsBySource = Dictionary(uniqueKeysWithValues: fixture.sources.map { ($0.id, Set($0.segments.map(\.id))) })
            let allSegments = segmentsBySource.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let texts = Dictionary(uniqueKeysWithValues: fixture.sources.flatMap { $0.segments.map { ($0.id, $0.text) } })
            for forbidden in fixture.expected.mustNotAssert {
                #expect(entities[forbidden.subject] != nil, "\(fixture.id): unknown subject in mustNotAssert")
                let scope = forbidden.source.flatMap { segmentsBySource[$0] } ?? allSegments
                #expect(!forbidden.segmentIDs.isEmpty && Set(forbidden.segmentIDs).isSubset(of: scope),
                        "\(fixture.id): a refusal names the segments that tempt it")
                let tempting = forbidden.segmentIDs.compactMap { texts[$0] }.joined(separator: " ")
                #expect(!forbidden.quote.isEmpty && tempting.contains(forbidden.quote),
                        "\(fixture.id): a refusal quotes its tempting span verbatim")
                #expect(KnowledgeFixtureVocabulary.predicates.contains(forbidden.predicate))
                if let object = forbidden.object { #expect(entities[object] != nil) }
                if let source = forbidden.source { #expect(sources.contains(source)) }
                #expect(!forbidden.reason.isEmpty)
            }
            for pair in fixture.expected.mustNotMerge {
                #expect(pair.count == 2 && pair[0] != pair[1], "\(fixture.id): a separation names two entities")
                let kinds = pair.compactMap { entities[$0]?.kind }
                #expect(kinds.count == 2 && kinds[0] == kinds[1], "\(fixture.id): a separation pairs same-kind entities")
            }
        }
    }

    /// Every claimed hard case names the segments that exhibit it, and each of
    /// those segments is something the expectations actually rely on — cited as
    /// evidence or named by a refusal — so deleting or rewriting the segment
    /// that makes a case hard fails the suite instead of leaving a claim behind.
    @Test func claimedHardCasesPointAtSegmentsTheExpectationsUse() throws {
        for fixture in try Self.loadAll() {
            #expect(Set(fixture.caseSegments.keys) == Set(fixture.covers), "\(fixture.id): caseSegments must map every covered case")
            let segments = Set(fixture.sources.flatMap { $0.segments.map(\.id) })
            let cited = Set(fixture.expected.assertions.flatMap { $0.evidence.flatMap(\.segmentIDs) })
            let refused = Set(fixture.expected.mustNotAssert.flatMap(\.segmentIDs))
            for (hardCase, ids) in fixture.caseSegments {
                #expect(!ids.isEmpty, "\(fixture.id)/\(hardCase): no segment named")
                for id in ids {
                    #expect(segments.contains(id), "\(fixture.id)/\(hardCase): unknown segment \(id)")
                    #expect(cited.contains(id) || refused.contains(id), "\(fixture.id)/\(hardCase): \(id) is used by no expectation")
                }
            }
            // Cases whose whole point is that a tempting segment yields nothing true
            // must have a refusal naming that segment.
            for hardCase in ["irony", "promptInjection", "wrongSpeaker", "provisionalDecision", "forecastNotDecision"] {
                for id in fixture.caseSegments[hardCase] ?? [] {
                    #expect(refused.contains(id), "\(fixture.id)/\(hardCase): \(id) needs a refusal")
                }
            }
            // Every relative-date segment resolves to a date value or a
            // coarser-than-day validity in an assertion that cites it.
            for id in fixture.caseSegments["relativeDate"] ?? [] {
                let resolved = fixture.expected.assertions.contains { assertion in
                    assertion.evidence.contains { $0.segmentIDs.contains(id) }
                        && (assertion.value?.type == "date" || assertion.precision == "month")
                }
                #expect(resolved, "\(fixture.id)/\(id): a relative date must resolve to a date or a month")
            }
            // Reopening is an explicit status change cited from the reopening segment.
            if let ids = fixture.caseSegments["reopen"] {
                let reopened = fixture.expected.assertions.contains { assertion in
                    assertion.value?.value == "reopened" && assertion.evidence.contains { !Set($0.segmentIDs).isDisjoint(with: ids) }
                }
                #expect(reopened, "\(fixture.id): reopening must be an asserted status change")
            }
        }
    }

    /// A fixture that claims a hard case must actually contain it.
    @Test func claimedHardCasesAreStructurallyPresent() throws {
        for fixture in try Self.loadAll() {
            let covers = Set(fixture.covers)
            if covers.contains("lateArrival") {
                let late = fixture.sources.contains { early in
                    fixture.sources.contains { later in
                        early.recordedAt < later.recordedAt && early.ingestedAt > later.ingestedAt
                    }
                }
                #expect(late, "\(fixture.id): no source arrives after a later meeting")
            }
            if covers.contains("correctedTranscript") {
                let corrected = fixture.sources.contains { source in
                    guard let earlier = source.correctedFrom, !earlier.isEmpty else { return false }
                    let current = Dictionary(uniqueKeysWithValues: source.segments.map { ($0.id, $0.text) })
                    return earlier.allSatisfy { current[$0.id] != nil && current[$0.id] != $0.text }
                }
                #expect(corrected, "\(fixture.id): no segment differs from its earlier revision")
            }
            if covers.contains("homonyms") {
                #expect(!fixture.expected.mustNotMerge.isEmpty, "\(fixture.id): homonyms need a separation")
            }
            if covers.contains("promptInjection") || covers.contains("provisionalDecision")
                || covers.contains("forecastNotDecision") || covers.contains("wrongSpeaker") {
                #expect(!fixture.expected.mustNotAssert.isEmpty, "\(fixture.id): needs a refusal")
            }
            if covers.contains("negation") {
                #expect(fixture.expected.assertions.contains { $0.polarity == "negative" })
            }
            if covers.contains("supersede") {
                #expect(fixture.expected.assertions.contains { $0.predicate == "supersedes" })
            }
            if covers.contains("units") {
                #expect(fixture.expected.assertions.contains { $0.value?.type == "number" && $0.value?.unit != nil })
            }
            if covers.contains("externalContexts") {
                let external = fixture.sources.filter { $0.context != "internalMeeting" && $0.organization != nil }
                #expect(Set(external.map(\.context)).count >= 2, "\(fixture.id): needs two external contexts")
                #expect(fixture.sources.contains { $0.context == "internalMeeting" })
            }
            if covers.contains("forecastNotDecision") {
                #expect(fixture.expected.assertions.contains { $0.claimKind == "analystForecast" && $0.modality == "hypothetical" })
            }
        }
    }
}

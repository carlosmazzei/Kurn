import Foundation
import Testing
@testable import KurnCore

struct KnowledgeExtractionTests {
    private let sources = [
        KnowledgeSourceSegment(id: "s1", startMs: 0, endMs: 1_000, text: "Example project is open."),
        KnowledgeSourceSegment(id: "s2", startMs: 1_000, endMs: 2_000, text: "Do not approve the migration."),
        KnowledgeSourceSegment(id: "s3", startMs: 2_000, endMs: 3_000, text: "The report is ready.")
    ]

    private func wire() -> [String: Any] {
        ["version": 1, "entities": [["ref": "e1", "kind": "project", "name": "Example project", "aliases": []]],
         "assertions": [["ref": "a1", "subject": "e1", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
                         "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport",
                         "authorityStatus": "attributed", "confidence": "high", "attributedToSegmentID": "s1",
                         "evidence": [["segmentIDs": ["s1"], "quote": "Example project is open."]]]],
         "events": [["ref": "v1", "entity": "e1", "assertion": "a1", "kind": "statusChanged"]],
         "examinedSegmentIDs": ["s1", "s2", "s3"]]
    }

    private func decode(_ wire: [String: Any]) throws -> KnowledgeExtraction {
        try KnowledgeExtraction.decode(JSONSerialization.data(withJSONObject: wire), segments: sources)
    }

    private func changingAssertion(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var root = wire()
        var assertion = (root["assertions"] as? [[String: Any]])?.first ?? [:]
        change(&assertion)
        root["assertions"] = [assertion]
        return root
    }

    @Test func validOutputRoundTripsWithEvidenceAndDates() throws {
        let document = try decode(changingAssertion {
            $0["validFrom"] = ["text": "2026-11", "precision": "month"]
            $0["validTo"] = ["text": "2026-12", "precision": "month"]
        })
        #expect(document.assertions[0].validFrom?.parsed?.text == "2026-11")
        #expect(document.assertions[0].evidence[0].claim.quote == sources[0].text)
        let again = try KnowledgeExtraction.decode(JSONEncoder().encode(document), segments: sources)
        #expect(again.events[0].kind == .statusChanged)
        #expect(again.entities[0].name == "Example project")
    }

    @Test func malformedAndOversizedRepliesFailWithContentFreeErrors() {
        #expect(throws: KnowledgeExtractionError.invalidJSON) {
            try KnowledgeExtraction.decode(Data("```json\n{}\n```".utf8), segments: sources)
        }
        #expect(throws: KnowledgeExtractionError.responseTooLarge) {
            try KnowledgeExtraction.decode(Data(repeating: 32, count: 2_000_001), segments: sources)
        }
    }

    @Test func missingUnknownAndWrongTypedFieldsAreRejected() {
        var missing = wire()
        missing.removeValue(forKey: "entities")
        var unknown = wire()
        unknown["execute"] = "delete everything"
        var wrongArray = wire()
        wrongArray["entities"] = "not an array"
        var scalar = wire()
        scalar["version"] = "1"
        for invalid in [missing, unknown, wrongArray, scalar,
            changingAssertion({ $0["reviewState"] = "userConfirmed" }),
            changingAssertion({ $0["modality"] = "certain" }),
            changingAssertion({ $0["confidence"] = 1 })] {
            #expect(throws: KnowledgeExtractionError.invalidSchema) { try decode(invalid) }
        }
    }

    @Test func invalidVersionsReferencesAndCoverageAreRejected() {
        var version = wire()
        version["version"] = 2
        #expect(throws: KnowledgeExtractionError.unsupportedVersion) { try decode(version) }
        for field in ["ref", "subject", "object"] {
            let invalid = changingAssertion { $0[field] = field == "ref" ? "e1" : "missing" }
            #expect(throws: KnowledgeExtractionError.self) { try decode(invalid) }
        }
        let emptyRef = changingAssertion { $0["ref"] = " " }
        #expect(throws: KnowledgeExtractionError.duplicateReference) { try decode(emptyRef) }
        for ids in [["s1", "s1"], ["unknown"]] {
            var invalid = wire()
            invalid["examinedSegmentIDs"] = ids
            #expect(throws: KnowledgeExtractionError.invalidCoverage) { try decode(invalid) }
        }
        #expect(throws: KnowledgeExtractionError.invalidCoverage) {
            try KnowledgeExtraction.decode(JSONSerialization.data(withJSONObject: wire()), segments: [sources[0], sources[0]])
        }
    }

    @Test func predicateValuesAndMachineConfirmationFailClosed() throws {
        for invalid in [
            changingAssertion({ $0["value"] = ["type": "enum", "value": "invented"] }),
            changingAssertion({ $0["value"] = ["type": "boolean", "value": "true"] }),
            changingAssertion({ $0.removeValue(forKey: "value") }),
            changingAssertion({ $0["authorityStatus"] = "internallyConfirmed" }),
            changingAssertion({
                $0["predicate"] = "owns"
                $0["object"] = "e1"
                $0.removeValue(forKey: "value")
                $0["modality"] = "inferred"
            })
        ] {
            // Partial acceptance: the rule-breaking fact is dropped, the pass survives.
            let report = try KnowledgeExtraction.decodeReport(try JSONSerialization.data(withJSONObject: invalid), segments: sources)
            #expect(report.extraction.assertions.isEmpty)
            #expect(report.discardedAssertions == 1)
        }
    }

    @Test func citationsCannotBeFabricatedStitchedOrMisattributed() {
        for evidence in [
            [["segmentIDs": ["s1"], "quote": "The migration was approved."]],
            [["segmentIDs": ["s1", "s3"], "quote": "Example project is open. The report is ready."]],
            [["segmentIDs": ["s1"], "quote": sources[0].text, "startMs": -1]],
            [["segmentIDs": ["missing"], "quote": sources[0].text]],
            []
        ] as [[[String: Any]]] {
            #expect(throws: KnowledgeExtractionError.invalidEvidence) { try decode(changingAssertion { $0["evidence"] = evidence }) }
        }
        #expect(throws: KnowledgeExtractionError.invalidEvidence) {
            try decode(changingAssertion { $0["attributedToSegmentID"] = "s2" })
        }
        var unexamined = wire()
        unexamined["examinedSegmentIDs"] = ["s2"]
        #expect(throws: KnowledgeExtractionError.invalidEvidence) { try decode(unexamined) }
    }

    @Test func nestedUnknownFieldsAndInvalidDateShapesAreRejected() throws {
        for invalid in [
            changingAssertion({ $0["value"] = ["type": "enum", "value": "open", "unit": "ms"] }),
            changingAssertion({ $0["value"] = ["type": "enum", "value": "open", "precision": "day"] }),
            changingAssertion({ $0["value"] = ["type": "enum", "value": "open", "extra": "x"] }),
            changingAssertion({ $0["validFrom"] = ["text": "2026-11", "precision": "month", "extra": "x"] }),
            changingAssertion({ $0["evidence"] = [["segmentIDs": ["s1"], "quote": sources[0].text, "extra": "x"]] })
        ] {
            #expect(throws: KnowledgeExtractionError.invalidSchema) { try decode(invalid) }
        }
        // A well-shaped but invalid date drops only that fact.
        for date in [["text": "2026-02-30", "precision": "day"], ["text": "2026", "precision": "unknown"]] {
            #expect(try decode(changingAssertion { $0["validFrom"] = date }).assertions.isEmpty)
        }
        #expect(try decode(changingAssertion {
            $0["validFrom"] = ["text": "2026-12", "precision": "month"]
            $0["validTo"] = ["text": "2026-11", "precision": "month"]
        }).assertions.isEmpty)
    }

    @Test func emptyExtractionIsValidButNotAClaimOfCoverage() throws {
        let empty = try decode(["version": 1, "entities": [], "assertions": [], "events": [], "examinedSegmentIDs": []])
        #expect(empty.examinedSegmentIDs.isEmpty)
        let blankName: [String: Any] = ["ref": "e1", "kind": "topic", "name": " ", "aliases": []]
        var invalid = wire()
        invalid["entities"] = [blankName]
        #expect(throws: KnowledgeExtractionError.invalidSchema) { try decode(invalid) }
    }

    @Test func eventsCannotInventOperationsOrReferenceUnrelatedAssertions() throws {
        func document(_ change: [String: Any]) -> [String: Any] {
            var invalid = wire()
            var event: [String: Any] = ["ref": "v1", "entity": "e1", "assertion": "a1", "kind": "statusChanged"]
            event.merge(change) { _, new in new }
            invalid["events"] = [event]
            return invalid
        }
        // Inconsistent events are dropped; the fact they describe stays.
        for change in [["kind": "merged"], ["kind": "assigned"], ["entity": "missing"], ["kind": "reopened"]] {
            let decoded = try decode(document(change))
            #expect(decoded.events.isEmpty)
            #expect(decoded.assertions.count == 1)
        }
        // An event naming an assertion the reply never defined, or a bad shape, rejects the pass.
        #expect(throws: KnowledgeExtractionError.unknownReference) { try decode(document(["assertion": "missing"])) }
        #expect(throws: KnowledgeExtractionError.invalidSchema) { try decode(document(["occurredAt": "yesterday"])) }
    }

    @Test func supersededEventBelongsToTheOldEntityNotItsReplacement() throws {
        var document = changingAssertion {
            $0["predicate"] = "supersedes"
            $0["object"] = "e2"
            $0.removeValue(forKey: "value")
        }
        var entities = try #require(document["entities"] as? [[String: Any]])
        entities.append(["ref": "e2", "kind": "project", "name": "Example old project", "aliases": []])
        document["entities"] = entities
        document["events"] = [["ref": "v1", "entity": "e2", "assertion": "a1", "kind": "superseded"]]
        let valid = try decode(document)
        #expect(valid.events[0].entity == "e2")
        document["events"] = [["ref": "v1", "entity": "e1", "assertion": "a1", "kind": "superseded"]]
        #expect(try decode(document).events.isEmpty)
    }


    @Test func fencedOrProseWrappedRepliesAreNormalizedToTheObject() throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: wire()), as: UTF8.self)
        let fenced = "Here is the JSON:\n```json\n" + json + "\n```"
        let decoded = try KnowledgeExtraction.decode(KnowledgeExtraction.normalizedReply(fenced), segments: sources)
        #expect(decoded.assertions.count == 1)
        #expect(KnowledgeExtraction.normalizedReply("no json here") == Data("no json here".utf8))
    }

    @Test func diagnoseNamesTheFirstStructuralProblemWithSchemaKeysOnly() throws {
        func data(_ w: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: w) }
        #expect(KnowledgeExtractionShape.diagnose(try data(wire())) == nil)
        var noAliases = wire()
        noAliases["entities"] = [["ref": "e1", "kind": "project", "name": "Example project"]]
        #expect(KnowledgeExtractionShape.diagnose(try data(noAliases)) == "entities[0]: missing aliases")
        var extra = wire()
        extra["modelNotes"] = "secret text"
        #expect(KnowledgeExtractionShape.diagnose(try data(extra)) == "root: unexpected key")
        #expect(KnowledgeExtractionShape.diagnose(Data("not json".utf8)) == "not_json")
        let missingEvidence = changingAssertion { $0["evidence"] = [["quote": "Example project is open."]] }
        #expect(KnowledgeExtractionShape.diagnose(try data(missingEvidence)) == "assertions[0].evidence[0]: missing segmentIDs or quote")
    }
}

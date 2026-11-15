import Foundation
import Testing
@testable import KurnCore

struct KnowledgeWikiProjectorTests {
    private let subject = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let object = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func entity(_ id: UUID, kind: KnowledgeEntityKind = .project, target: UUID? = nil) -> KnowledgeWikiSnapshot.Entity {
        .init(id: id, kind: kind, name: id == subject ? "Example [portal]" : "Example team", aliases: ["Alias"], targetID: target)
    }

    private func fact(predicate: KnowledgePredicate = .hasStatus, value: KnowledgeTypedValue? = .enumeration("open"),
                      objectID: UUID? = nil, modality: KnowledgeModality = .proposed) -> KnowledgeWikiSnapshot.Fact {
        .init(id: UUID(), subjectID: subject, predicate: predicate, objectID: objectID, value: value,
            qualifiers: .init(modality: modality, polarity: .negative, claimKind: .internalProposal,
                authority: .unverified, confidence: .low, review: .machineExtracted,
                validFrom: KnowledgeTemporalValue(text: "2026-11", precision: .month)),
            source: .init(meetingID: UUID(), recordedAt: Date(timeIntervalSince1970: 1_000), evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["anchor"], quote: "Not approved. <img src=x> [tap](https://example.test)",
                    startMs: 0, endMs: 1_000, attributedSpeaker: "Speaker 1")]))
    }

    @Test func deterministicSectionsPreserveEveryAttributedClaimAndBothTimes() throws {
        let first = fact()
        let later = fact(modality: .disputed)
        let input = KnowledgeWikiSnapshot(revision: 9, entities: [entity(subject)], facts: [first, later])
        let pages = try KnowledgeWikiProjector.project(input)
        let reversed = try KnowledgeWikiProjector.project(.init(revision: 9, entities: input.entities.reversed(), facts: input.facts.reversed()))
        #expect(pages == reversed)
        let page = try #require(pages.first)
        #expect(page.sections.flatMap(\.entries).count == 2)
        #expect(page.markdown.contains("negative; proposed; internalProposal; unverified"))
        #expect(page.markdown.contains("negative; disputed"))
        #expect(page.markdown.contains("2026-11 (month), unknown"))
        #expect(page.markdown.contains("learned: 1970-01-01T00:16:40Z"))
        #expect(page.markdown.contains("evidence:\(first.source.evidence[0].id.uuidString.lowercased())"))
        #expect(page.markdown.contains("\\<img"))
        #expect(!page.markdown.contains("https://"))
        #expect(!page.markdown.contains("[tap]"))
        #expect(page.markdown.contains("Example \\[portal\\]"))
        #expect(try JSONDecoder().decode([KnowledgeWikiPage].self, from: JSONEncoder().encode(pages)) == pages)
    }

    @Test func redirectsUnifyViewsWithoutChangingFactIDsOrDirection() throws {
        let fact = fact(predicate: .dependsOn, value: nil, objectID: object)
        let root = UUID()
        let pages = try KnowledgeWikiProjector.project(.init(revision: 1,
            entities: [entity(subject, target: root), entity(object), entity(root)], facts: [fact]))
        #expect(pages.count == 2)
        let page = try #require(pages.first { $0.entity.id == root })
        let entry = try #require(page.sections.first?.entries.first)
        #expect(entry.fact.subjectID == subject)
        #expect(entry.fact.id == fact.id)
        #expect(entry.subject.id == root)
        #expect(entry.object?.id == object)
        #expect(page.entity.aliases.contains("Example [portal]"))
        #expect(page.markdown.contains("entity:\(object.uuidString.lowercased())"))
    }

    @Test func optionalNarrativeResolvesOnlyPageAssertionsAndEscapesItsText() throws {
        let fact = fact()
        let input = KnowledgeWikiSnapshot(revision: 1, entities: [entity(subject)], facts: [fact])
        let paragraph = KnowledgeWikiNarrative.Paragraph(text: "# Forged [route](entity:unknown)\n<script>x</script>", assertionIDs: [fact.id])
        let narrative = KnowledgeWikiNarrative(entityID: subject, paragraphs: [paragraph])
        let page = try #require(KnowledgeWikiProjector.project(input, narratives: [narrative]).first)
        #expect(page.narrative == narrative)
        #expect(page.markdown.contains("Generated narrative"))
        #expect(!page.markdown.contains("[route](entity:"))
        #expect(page.markdown.contains("\\<script\\>"))
        #expect(page.markdown.contains("\\# Forged"))
        for invalid in [
            KnowledgeWikiNarrative(entityID: UUID(), paragraphs: [paragraph]),
            KnowledgeWikiNarrative(entityID: subject, paragraphs: []),
            KnowledgeWikiNarrative(entityID: subject, paragraphs: [.init(text: " ", assertionIDs: [fact.id])]),
            KnowledgeWikiNarrative(entityID: subject, paragraphs: [.init(text: "Claim", assertionIDs: [])]),
            KnowledgeWikiNarrative(entityID: subject, paragraphs: [.init(text: "Claim", assertionIDs: [UUID()])]),
            KnowledgeWikiNarrative(entityID: subject, paragraphs: [.init(text: "Claim", assertionIDs: [fact.id, fact.id])]),
            KnowledgeWikiNarrative(entityID: subject, paragraphs: [.init(text: String(repeating: "x", count: 2_049), assertionIDs: [fact.id])])
        ] {
            #expect(throws: KnowledgeWikiProjectionError.invalidNarrative) { try KnowledgeWikiProjector.project(input, narratives: [invalid]) }
        }
        #expect(throws: KnowledgeWikiProjectionError.invalidNarrative) { try KnowledgeWikiProjector.project(input, narratives: [narrative, narrative]) }
        #expect(throws: KnowledgeWikiProjectionError.unsupportedNarrative) {
            try KnowledgeWikiProjector.project(input, narratives: [.init(version: 99, entityID: subject, paragraphs: [paragraph])])
        }
    }

    @Test func allStructuredSectionsAndTypedObjectsRenderWithoutInferringState() throws {
        for kind in KnowledgeEntityKind.allCases {
            for value in [KnowledgeTypedValue.string("<hello>"), .number(3, unit: "items"), .number(1.5, unit: nil),
                          .boolean(false), .date(KnowledgeTemporalValue(text: "2026-11-15", precision: .day)!), .enumeration("open")] {
                let predicate: KnowledgePredicate = switch value {
                case .number, .string: .reportsMetric
                case .date: .dueOn
                default: .hasStatus
                }
                let candidate = fact(predicate: predicate, value: value)
                if predicate.violation(subjectKind: kind, objectKind: nil, value: value) != nil { continue }
                let pages = try KnowledgeWikiProjector.project(.init(revision: 1, entities: [entity(subject, kind: kind)], facts: [candidate]))
                #expect(pages.count == 1)
                #expect(!pages[0].markdown.isEmpty)
            }
        }
    }

    @Test func invalidShapesReferencesAndOversizeSnapshotsAreRefused() throws {
        let fact = fact()
        let entity = entity(subject)
        for input in [
            KnowledgeWikiSnapshot(revision: -1, entities: [entity], facts: []),
            .init(revision: 1, entities: [entity, entity], facts: []),
            .init(revision: 1, entities: [entity], facts: [fact, fact]),
            .init(revision: 1, entities: [], facts: [fact]),
            .init(revision: 1, entities: [.init(id: subject, kind: .project, name: " ")], facts: []),
            .init(revision: 1, entities: [entity], facts: [self.fact(predicate: .dependsOn, value: nil, objectID: object)])
        ] {
            #expect(throws: KnowledgeWikiProjectionError.invalidSnapshot) { try KnowledgeWikiProjector.project(input) }
        }
        #expect(throws: KnowledgeWikiProjectionError.projectionLimit) {
            try KnowledgeWikiProjector.project(.init(revision: 1, entities: Array(repeating: entity, count: 2_049), facts: []))
        }
        #expect(throws: KnowledgeEntityResolutionError.redirectCycle) {
            try KnowledgeWikiProjector.project(.init(revision: 1, entities: [self.entity(subject, target: subject)], facts: []))
        }
        #expect(try KnowledgeWikiProjector.project(.init(revision: 0, entities: [], facts: [])).isEmpty)
    }

    @Test func temporalCodecRetainsPrecisionAndRejectsImpossibleDates() throws {
        for (text, precision) in [("2026-11", KnowledgeTemporalPrecision.month), ("2026-11-15", .day), ("2026-11-15T13:40:00Z", .instant)] {
            let value = try #require(KnowledgeTemporalValue(text: text, precision: precision))
            #expect(try JSONDecoder().decode(KnowledgeTemporalValue.self, from: JSONEncoder().encode(value)) == value)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KnowledgeTemporalValue.self, from: Data(#"{"text":"2026-02-30","precision":"day"}"#.utf8))
        }
    }
}

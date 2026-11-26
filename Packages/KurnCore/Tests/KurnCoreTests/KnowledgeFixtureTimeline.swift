import Foundation
import Testing
@testable import KurnCore

/// A golden fixture's expected assertions as temporal claims: valid time as
/// stated, and transaction time from the meeting's import (`ingestedAt`).
struct KnowledgeFixtureTimeline {
    let claims: [KnowledgeTemporalClaim]
    let entities: [String: UUID]
    let assertions: [String: UUID]
    /// The same claims as an authorized wiki snapshot (meeting dates as recorded).
    let snapshot: KnowledgeWikiSnapshot

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text.count == 10 ? text + "T12:00:00Z" : text)!
    }

    static func day(_ text: String) -> KnowledgeTemporalValue { KnowledgeTemporalValue(text: text, precision: .day)! }

    private struct Fixture: Decodable {
        struct Source: Decodable { let id: String; let recordedAt: String; let ingestedAt: String }
        struct Entity: Decodable { let ref: String; let kind: KnowledgeEntityKind; let name: String }
        struct Evidence: Decodable { let source: String; let segmentIDs: [String]; let quote: String }
        struct Assertion: Decodable {
            let ref: String, subject: String, predicate: KnowledgePredicate, object: String?
            let value: KnowledgeTypedValue?, modality: KnowledgeModality, polarity: KnowledgePolarity
            let validFrom: String, precision: KnowledgeTemporalPrecision, evidence: [Evidence]
            let claimKind: KnowledgeClaimKind
        }
        struct Expected: Decodable { let entities: [Entity]; let assertions: [Assertion] }
        let sources: [Source]
        let expected: Expected
    }

    static func load(_ name: String) throws -> KnowledgeFixtureTimeline {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/knowledge"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let ingested = Dictionary(uniqueKeysWithValues: fixture.sources.map { ($0.id, date($0.ingestedAt)) })
        let entities = Dictionary(uniqueKeysWithValues: fixture.expected.entities.map { ($0.ref, UUID()) })
        let recorded = Dictionary(uniqueKeysWithValues: fixture.sources.map { ($0.id, date($0.recordedAt)) })
        let meetings = Dictionary(uniqueKeysWithValues: fixture.sources.map { ($0.id, UUID()) })
        var claims: [KnowledgeTemporalClaim] = [], ids: [String: UUID] = [:], facts: [KnowledgeWikiSnapshot.Fact] = []
        for row in fixture.expected.assertions {
            let source = try #require(row.evidence.first?.source)
            let subject = try #require(entities[row.subject])
            let recordedAt = try #require(ingested[source])
            let claim = KnowledgeTemporalClaim(
                id: UUID(), subjectID: subject, predicate: row.predicate, objectID: row.object.flatMap { entities[$0] },
                value: row.value, polarity: row.polarity, modality: row.modality,
                validFrom: KnowledgeTemporalValue(text: row.validFrom, precision: row.precision), recordedAt: recordedAt,
                observedAt: recorded[source])
            ids[row.ref] = claim.id
            claims.append(claim)
            let evidence = row.evidence.enumerated().map { index, cited in
                KnowledgeWikiSnapshot.Evidence(id: UUID(), recordingID: UUID(), segmentIDs: cited.segmentIDs, quote: cited.quote,
                                               startMs: index * 1_000, endMs: index * 1_000 + 500, attributedSpeaker: "Speaker 1")
            }
            let meetingID = try #require(meetings[source]), meetingDate = try #require(recorded[source])
            facts.append(KnowledgeWikiSnapshot.Fact(
                id: claim.id, subjectID: subject, predicate: row.predicate, objectID: claim.objectID, value: row.value,
                qualifiers: .init(modality: row.modality, polarity: row.polarity, claimKind: row.claimKind, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted, validFrom: claim.validFrom),
                source: .init(meetingID: meetingID, recordedAt: meetingDate, observedAt: meetingDate, evidence: evidence)))
        }
        let snapshotEntities = try fixture.expected.entities.map { entity in
            KnowledgeWikiSnapshot.Entity(id: try #require(entities[entity.ref]), kind: entity.kind, name: entity.name)
        }
        return KnowledgeFixtureTimeline(claims: claims, entities: entities, assertions: ids,
                                        snapshot: KnowledgeWikiSnapshot(revision: 1, entities: snapshotEntities, facts: facts))
    }
}

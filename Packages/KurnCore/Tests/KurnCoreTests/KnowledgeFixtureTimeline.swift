import Foundation
import Testing
@testable import KurnCore

/// A golden fixture's expected assertions as temporal claims: valid time as
/// stated, and transaction time from the meeting's import (`ingestedAt`).
struct KnowledgeFixtureTimeline {
    let claims: [KnowledgeTemporalClaim]
    let entities: [String: UUID]
    let assertions: [String: UUID]

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text.count == 10 ? text + "T12:00:00Z" : text)!
    }

    static func day(_ text: String) -> KnowledgeTemporalValue { KnowledgeTemporalValue(text: text, precision: .day)! }

    private struct Fixture: Decodable {
        struct Source: Decodable { let id: String; let ingestedAt: String }
        struct Entity: Decodable { let ref: String }
        struct Evidence: Decodable { let source: String }
        struct Assertion: Decodable {
            let ref: String, subject: String, predicate: KnowledgePredicate, object: String?
            let value: KnowledgeTypedValue?, modality: KnowledgeModality, polarity: KnowledgePolarity
            let validFrom: String, precision: KnowledgeTemporalPrecision, evidence: [Evidence]
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
        var claims: [KnowledgeTemporalClaim] = [], ids: [String: UUID] = [:]
        for row in fixture.expected.assertions {
            let source = try #require(row.evidence.first?.source)
            let subject = try #require(entities[row.subject])
            let recordedAt = try #require(ingested[source])
            let claim = KnowledgeTemporalClaim(
                id: UUID(), subjectID: subject, predicate: row.predicate, objectID: row.object.flatMap { entities[$0] },
                value: row.value, polarity: row.polarity, modality: row.modality,
                validFrom: KnowledgeTemporalValue(text: row.validFrom, precision: row.precision), recordedAt: recordedAt)
            ids[row.ref] = claim.id
            claims.append(claim)
        }
        return KnowledgeFixtureTimeline(claims: claims, entities: entities, assertions: ids)
    }
}

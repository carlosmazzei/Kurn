import Foundation
import KurnCore
import Testing
@testable import Kurn

struct KnowledgeLateArrivalPresentationTests {
    private static let english = Locale(identifier: "en_US")
    private static let utc = TimeZone(identifier: "UTC")!

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private static func page(_ statuses: [(String, String, String)]) throws -> KnowledgeWikiPage {
        let entity = UUID()
        let facts = try statuses.map { value, stated, recorded in
            // Bound first: inside an argument of optional type, #require would
            // check the promoted optional and never fail.
            let validFrom = try #require(KnowledgeTemporalValue(text: stated, precision: .day))
            return KnowledgeWikiSnapshot.Fact(
                id: UUID(), subjectID: entity, predicate: .hasStatus, value: .enumeration(value),
                qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted,
                                  validFrom: validFrom),
                source: .init(meetingID: UUID(), recordedAt: try date(recorded), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ]))
        }
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: [.init(id: entity, kind: .project, name: "Portal")], facts: facts)
        return try #require(KnowledgeWikiProjector.project(snapshot).first)
    }

    @Test func aLateStatusIsNamedByWhenItWasRecordedAndTheDaysItChanged() throws {
        let page = try Self.page([("open", "2026-03-01", "2026-03-01T12:00:00Z"),
                                  ("blocked", "2026-04-01", "2026-06-01T12:00:00Z")])
        let items = KnowledgeLateArrivalPresentation.items(page: page, locale: Self.english, timeZone: Self.utc)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.title == String(format: KnowledgeLateArrivalPresentation.copy("recorded"), "Jun 1, 2026"))
        #expect(item.stretches.map(\.title) == [
            String(format: KnowledgeLateArrivalPresentation.copy("on"), "Apr 1, 2026"),
            String(format: KnowledgeLateArrivalPresentation.copy("from"), "Apr 2, 2026"),
        ])
        // On April 1 the new status may already hold and open grows uncertain;
        // from April 2 it replaced open, which the row names as what came before.
        let shifted = KnowledgeComparePresentation.copy("certainty_changed")
        #expect(item.stretches[0].rows.count == 2 && item.stretches[0].rows.contains { $0.notes.contains(shifted) })
        let change = try #require(item.stretches[1].rows.first)
        #expect(item.stretches[1].rows.count == 1 && change.before != nil && change.evidence != nil)
        #expect(change.notes.first == KnowledgeComparePresentation.copy("kind.changed"))
        #expect(item.stretches[0].rows.map { $0.notes.first } == [
            KnowledgeComparePresentation.copy("kind.started"), KnowledgeComparePresentation.copy("kind.unchanged"),
        ])
    }

    @Test func conflictingStatesALateArrivalSettlesAreMarkedAsEnded() throws {
        // Open and blocked conflict from March; ready, stated for May and
        // recorded in June, ends both rather than replacing either one.
        let page = try Self.page([("open", "2026-03-01", "2026-03-01T12:00:00Z"),
                                  ("blocked", "2026-03-01", "2026-03-01T12:00:00Z"),
                                  ("ready", "2026-05-01", "2026-06-01T12:00:00Z")])
        let item = try #require(KnowledgeLateArrivalPresentation.items(page: page, locale: Self.english, timeZone: Self.utc).first)
        let settled = try #require(item.stretches.last)
        let kinds = settled.rows.compactMap { $0.notes.first }
        #expect(kinds.filter { $0 == KnowledgeComparePresentation.copy("kind.ended") }.count == 2)
        #expect(kinds.filter { $0 == KnowledgeComparePresentation.copy("kind.started") }.count == 1)
    }

    @Test func aPageWithNothingLateShowsNothing() throws {
        let page = try Self.page([("open", "2026-03-01", "2026-03-01T12:00:00Z"),
                                  ("ready", "2026-05-01", "2026-05-01T12:00:00Z")])
        #expect(KnowledgeLateArrivalPresentation.items(page: page, locale: Self.english, timeZone: Self.utc).isEmpty)
    }

    @Test func aStretchSpanningSeveralDaysNamesItsLastDay() throws {
        let comparison = KnowledgeStateComparison.compare(
            entityID: UUID(), earlier: .init(validAt: Date(), knownAt: Date()), later: .init(validAt: Date(), knownAt: Date()), claims: [])
        let segment = KnowledgeLateArrival.Segment(lower: try Self.date("2026-04-01T00:00:00Z"),
                                                   upper: try Self.date("2026-04-05T00:00:00Z"), comparison: comparison)
        #expect(KnowledgeLateArrivalPresentation.range(segment, locale: Self.english)
            == String(format: KnowledgeLateArrivalPresentation.copy("range"), "Apr 1, 2026", "Apr 4, 2026"))
    }
}

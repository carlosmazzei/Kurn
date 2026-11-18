import Foundation
import KurnCore
import Testing
@testable import Kurn

struct KnowledgeComparePresentationTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text + "T12:00:00Z"))
    }

    private static func day(_ text: String) throws -> KnowledgeTemporalValue {
        try #require(KnowledgeTemporalValue(text: text, precision: .day))
    }

    /// A decision approved on March 1 and revised on May 1, blocked by a team
    /// from April 1, and no longer blocked from June 1.
    private struct Fixture {
        let pages: [KnowledgeWikiPage]
        let decision: UUID, team: UUID
        let approved: KnowledgeWikiSnapshot.Fact, revised: KnowledgeWikiSnapshot.Fact
        let blocks: KnowledgeWikiSnapshot.Fact, unblocked: KnowledgeWikiSnapshot.Fact
    }

    private static func fixture() throws -> Fixture {
        let decision = UUID(), team = UUID()
        func fact(_ subject: UUID, _ predicate: KnowledgePredicate, object: UUID? = nil, value: KnowledgeTypedValue? = nil,
                  from: String, polarity: KnowledgePolarity = .positive) throws -> KnowledgeWikiSnapshot.Fact {
            KnowledgeWikiSnapshot.Fact(
                id: UUID(), subjectID: subject, predicate: predicate, objectID: object, value: value,
                qualifiers: .init(modality: .reported, polarity: polarity, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted, validFrom: try day(from)),
                source: .init(meetingID: UUID(), recordedAt: try date(from), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ]))
        }
        let approved = try fact(decision, .hasStatus, value: .enumeration("approved"), from: "2026-03-01")
        let revised = try fact(decision, .hasStatus, value: .enumeration("revised"), from: "2026-05-01")
        let blocks = try fact(team, .blocks, object: decision, from: "2026-04-01")
        let unblocked = try fact(team, .blocks, object: decision, from: "2026-06-01", polarity: .negative)
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: [
            .init(id: decision, kind: .decisionThread, name: "Rollout"), .init(id: team, kind: .team, name: "Security"),
        ], facts: [approved, revised, blocks, unblocked])
        return Fixture(pages: try KnowledgeWikiProjector.project(snapshot), decision: decision, team: team,
                       approved: approved, revised: revised, blocks: blocks, unblocked: unblocked)
    }

    @Test func daysAreReadInThePersonsCalendar() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-03-01T20:00:00Z"))
        #expect(KnowledgeComparePresentation.day(lateEvening, calendar: Self.utc)?.text == "2026-03-01")
        #expect(KnowledgeComparePresentation.day(lateEvening, calendar: tokyo)?.text == "2026-03-02")
    }

    @Test func aChangeShowsWhatItWasAndLinksToItsEvidence() throws {
        let fixture = try Self.fixture()
        let comparison = try #require(KnowledgeComparePresentation.compare(
            entityID: fixture.decision, from: try Self.date("2026-04-15"), to: try Self.date("2026-05-15"),
            asKnownThen: false, pages: fixture.pages, calendar: Self.utc))
        let sections = KnowledgeComparePresentation.sections(comparison, pages: fixture.pages)
        #expect(sections.map(\.kind) == [.changed, .unchanged])
        let change = try #require(sections.first?.rows.first)
        let format = NSLocalizedString("detail.knowledge.claim", comment: "")
        let revised = String(format: format, "Rollout", NSLocalizedString("knowledge.predicate.hasStatus", comment: ""),
                             NSLocalizedString("knowledge.status.revised", comment: ""))
        let approved = String(format: format, "Rollout", NSLocalizedString("knowledge.predicate.hasStatus", comment: ""),
                              NSLocalizedString("knowledge.status.approved", comment: ""))
        #expect(change.text == revised)
        #expect(change.before == String(format: KnowledgeComparePresentation.copy("before"), approved))
        #expect(change.evidence == .evidence(assertionID: fixture.revised.id, evidenceID: fixture.revised.source.evidence[0].id))
        // The blocker is named from the other side, in its own direction.
        let blocker = try #require(sections.last?.rows.first)
        #expect(blocker.text == String(format: format, "Security", NSLocalizedString("knowledge.predicate.blocks", comment: ""), "Rollout"))
        #expect(blocker.before == nil && blocker.notes.isEmpty)
    }

    @Test func aNegationReadsAsOneAndTheDaysMayComeInEitherOrder() throws {
        let fixture = try Self.fixture()
        let comparison = try #require(KnowledgeComparePresentation.compare(
            entityID: fixture.decision, from: try Self.date("2026-06-15"), to: try Self.date("2026-05-15"),
            asKnownThen: false, pages: fixture.pages, calendar: Self.utc))
        #expect(comparison.earlier.validAt < comparison.later.validAt)
        let sections = KnowledgeComparePresentation.sections(comparison, pages: fixture.pages)
        let change = try #require(sections.first { $0.kind == .changed }?.rows.first)
        let claim = String(format: NSLocalizedString("detail.knowledge.claim", comment: ""), "Security",
                           NSLocalizedString("knowledge.predicate.blocks", comment: ""), "Rollout")
        #expect(change.text == String(format: NSLocalizedString("detail.knowledge.negative_claim", comment: ""), claim))
    }

    @Test func asKnownThenHidesWhatWasRecordedLater() throws {
        let fixture = try Self.fixture()
        let now = try #require(KnowledgeComparePresentation.compare(
            entityID: fixture.decision, from: try Self.date("2026-03-15"), to: try Self.date("2026-05-15"),
            asKnownThen: false, pages: fixture.pages, calendar: Self.utc))
        let then = try #require(KnowledgeComparePresentation.compare(
            entityID: fixture.decision, from: try Self.date("2026-03-15"), to: try Self.date("2026-05-15"),
            asKnownThen: true, pages: fixture.pages, calendar: Self.utc))
        #expect(now.earlier.knownAt == .distantFuture)
        #expect(then.earlier.knownAt == then.earlier.validAt && then.later.knownAt == then.later.validAt)
        // Every claim here was recorded on the day it states, so both readings agree.
        #expect(then.later.holdings.count == now.later.holdings.count)
    }

    @Test func notesNameTentativeUncertainAndShiftingClaims() throws {
        let item = UUID()
        func fact(_ status: String, from: KnowledgeTemporalValue, modality: KnowledgeModality) throws -> KnowledgeWikiSnapshot.Fact {
            KnowledgeWikiSnapshot.Fact(
                id: UUID(), subjectID: item, predicate: .hasStatus, value: .enumeration(status),
                qualifiers: .init(modality: modality, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted, validFrom: from),
                source: .init(meetingID: UUID(), recordedAt: try Self.date("2026-01-01"), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ]))
        }
        let march = try #require(KnowledgeTemporalValue(text: "2026-03", precision: .month))
        let august = try #require(KnowledgeTemporalValue(text: "2026-08", precision: .month))
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: [.init(id: item, kind: .actionItem, name: "Runbook")], facts: [
            try fact("committed", from: march, modality: .reported), try fact("completed", from: august, modality: .proposed),
        ])
        let pages = try KnowledgeWikiProjector.project(snapshot)
        let shifted = try #require(KnowledgeComparePresentation.compare(
            entityID: item, from: try Self.date("2026-03-15"), to: try Self.date("2026-04-15"), asKnownThen: false,
            pages: pages, calendar: Self.utc))
        let unchanged = try #require(KnowledgeComparePresentation.sections(shifted, pages: pages).first?.rows.first)
        #expect(unchanged.notes == [KnowledgeComparePresentation.copy("certainty_changed")])
        let proposed = try #require(KnowledgeComparePresentation.compare(
            entityID: item, from: try Self.date("2026-07-01"), to: try Self.date("2026-08-15"), asKnownThen: false,
            pages: pages, calendar: Self.utc))
        let started = try #require(KnowledgeComparePresentation.sections(proposed, pages: pages).first { $0.kind == .started }?.rows.first)
        #expect(started.notes == [KnowledgeTimelinePresentation.text("tentative"), KnowledgeComparePresentation.copy("possible")])
    }

    @Test func theEarlierDayDefaultsToTheFirstStatedStart() throws {
        let fixture = try Self.fixture()
        let page = try #require(fixture.pages.first { $0.entity.id == fixture.decision })
        let now = try Self.date("2026-07-01")
        #expect(KnowledgeComparePresentation.defaultEarlierDate(page: page, now: now)
            == ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z"))
        for kind in KnowledgeStateComparison.ChangeKind.allCases {
            #expect(KnowledgeComparePresentation.copy("kind." + kind.rawValue) != "knowledge.compare.kind." + kind.rawValue)
        }
    }
}

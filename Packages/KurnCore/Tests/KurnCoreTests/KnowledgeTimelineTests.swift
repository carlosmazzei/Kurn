import Foundation
import Testing
@testable import KurnCore

/// K3.3: the timeline is placed by stated valid time, keeps undated claims
/// apart, and carries each lifecycle's findings onto the claims it names.
struct KnowledgeTimelineTests {
    private typealias Timeline = KnowledgeFixtureTimeline

    private static func pages(_ snapshot: KnowledgeWikiSnapshot) throws -> [KnowledgeWikiPage] {
        try KnowledgeWikiProjector.project(snapshot)
    }

    @Test func theProvisioningMeetingsFallIntoTheMonthsTheyState() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let timeline = KnowledgeTimeline.build(pages: try Self.pages(line.snapshot))
        #expect(timeline.periods.map(\.month.text) == ["2026-09", "2026-10", "2026-11"])
        #expect(timeline.undated.isEmpty)
        // A relation shown on both of its entities' pages is one entry.
        #expect(timeline.periods.flatMap(\.entries).count == line.snapshot.facts.count)
        let byRef = { (ref: String) throws -> KnowledgeTimeline.Entry in
            let id = try #require(line.assertions[ref])
            return try #require(timeline.periods.flatMap(\.entries).first { $0.factID == id })
        }
        #expect(try byRef("a2").kind == .status)
        #expect(try byRef("a2").isTentative)
        #expect(try byRef("a3").isTentative == false)
        #expect(try byRef("a4").kind == .dueDate)
        #expect(try byRef("a6").kind == .relation)
        #expect(try byRef("a8").kind == .supersession)
        #expect(try byRef("a1").kind == .attribute)
        #expect(timeline.periods.flatMap(\.entries).allSatisfy { $0.lifecycleAnomalies.isEmpty })
        // Within September the claims stated on the 10th come before those of the 25th.
        let september = try #require(timeline.periods.first).entries.map(\.factID)
        let tenth = try [byRef("a1").factID, byRef("a2").factID], later = try [byRef("a3").factID, byRef("a4").factID]
        #expect(Set(september.prefix(2)) == Set(tenth) && Set(september.suffix(2)) == Set(later))
    }

    @Test func filtersKeepOnlyTheKindsAndClaimsAsked() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let pages = try Self.pages(line.snapshot)
        let statuses = KnowledgeTimeline.build(pages: pages, filter: .init(kinds: [.status]))
        #expect(statuses.periods.flatMap(\.entries).allSatisfy { $0.kind == .status })
        #expect(statuses.periods.flatMap(\.entries).count == 5)
        let established = KnowledgeTimeline.build(pages: pages, filter: .init(kinds: [.status], includesTentative: false))
        #expect(established.periods.flatMap(\.entries).count == 4)
        #expect(!established.periods.flatMap(\.entries).contains { $0.factID == line.assertions["a2"] })
        #expect(KnowledgeTimeline.Filter().isDefault && !KnowledgeTimeline.Filter(includesNegated: false).isDefault)
    }

    @Test func kindTogglesNeverHideEverything() {
        let all = KnowledgeTimeline.Filter()
        let noStatus = all.showing(.status, false)
        #expect(!noStatus.shows(.status) && noStatus.shows(.relation))
        #expect(noStatus.kinds == Set(KnowledgeTimeline.EntryKind.allCases).subtracting([.status]))
        #expect(noStatus.showing(.status, true).isDefault)
        let onlyStatus = KnowledgeTimeline.Filter(kinds: [.status])
        #expect(onlyStatus.showing(.status, false) == onlyStatus)
        #expect(onlyStatus.showing(.dueDate, true).kinds == [.status, .dueDate])
        #expect(all.shows(.attribute) && !onlyStatus.shows(.attribute))
    }

    @Test func anActionStatedByMonthIsPlacedInItsMonthWithoutAnomaly() throws {
        let line = try Timeline.load("en-platform-review")
        let timeline = KnowledgeTimeline.build(pages: try Self.pages(line.snapshot), filter: .init(kinds: [.status]))
        let november = try #require(timeline.periods.first { $0.month.text == "2026-11" })
        let completed = try #require(line.assertions["a7"]), reopened = try #require(line.assertions["a8"])
        #expect(november.entries.map(\.factID).contains(completed) && november.entries.map(\.factID).contains(reopened))
        // November starts before the 12th, so the month-precision completion sorts first.
        let ids = november.entries.map(\.factID)
        let completedIndex = try #require(ids.firstIndex(of: completed)), reopenedIndex = try #require(ids.firstIndex(of: reopened))
        #expect(completedIndex < reopenedIndex)
        #expect(november.entries.allSatisfy { $0.lifecycleAnomalies.isEmpty })
    }

    // MARK: - Synthetic

    private static let meeting = UUID()
    private static let recorded = Timeline.date("2026-10-20")

    private static func fact(_ subject: UUID, status: String, on stated: KnowledgeTemporalValue?,
                             polarity: KnowledgePolarity = .positive) -> KnowledgeWikiSnapshot.Fact {
        KnowledgeWikiSnapshot.Fact(
            id: UUID(), subjectID: subject, predicate: .hasStatus, value: .enumeration(status),
            qualifiers: .init(modality: .reported, polarity: polarity, claimKind: .internalStatusReport, authority: .attributed,
                              confidence: .medium, review: .machineExtracted, validFrom: stated),
            source: .init(meetingID: meeting, recordedAt: recorded, evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                      attributedSpeaker: "Speaker 1"),
            ]))
    }

    @Test func undatedClaimsAreKeptApartAndLifecycleFindingsReachTheirClaims() throws {
        let decision = UUID()
        let approved = Self.fact(decision, status: "approved", on: try #require(KnowledgeTemporalValue(text: "2026-10", precision: .month)))
        let rejected = Self.fact(decision, status: "rejected", on: Timeline.day("2026-10-15"))
        let undated = Self.fact(decision, status: "revised", on: nil)
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: [.init(id: decision, kind: .decisionThread, name: "Rollout")],
                                             facts: [undated, rejected, approved])
        let timeline = KnowledgeTimeline.build(pages: try Self.pages(snapshot))
        #expect(timeline.undated.map(\.factID) == [undated.id])
        let october = try #require(timeline.periods.first).entries
        #expect(october.map(\.factID) == [approved.id, rejected.id])
        #expect(october.allSatisfy { $0.lifecycleAnomalies == [.invalidTransition, .unresolvedOrder] })
        #expect(KnowledgeTimeline.build(pages: try Self.pages(snapshot), filter: .init(kinds: [.relation])).isEmpty)
    }

    @Test func aDateStatedAfterItsMeetingIsAhead() throws {
        let item = UUID()
        let planned = Self.fact(item, status: "completed", on: Timeline.day("2026-11-30"))
        let past = Self.fact(item, status: "committed", on: Timeline.day("2026-10-01"))
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: [.init(id: item, kind: .actionItem, name: "Runbook")],
                                             facts: [planned, past])
        let entries = KnowledgeTimeline.build(pages: try Self.pages(snapshot)).periods.flatMap(\.entries)
        #expect(entries.first { $0.factID == planned.id }?.isAhead == true)
        #expect(entries.first { $0.factID == past.id }?.isAhead == false)
    }
}

//
//  KnowledgeObservedTimeTests.swift
//  KurnCoreTests
//
//  K7.1: source time is a third clock. A meeting compiled long after it happened
//  is known late but was said early; the three clocks are never mixed.
//

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeObservedTimeTests {
    private static func claims(_ ref: String, in line: KnowledgeFixtureTimeline) -> KnowledgeTemporalClaim? {
        line.claims.first { $0.id == line.assertions[ref] }
    }

    @Test func aLateImportedMeetingWasSaidEarlyButKnownLate() throws {
        // pt-provisioning-timeline: m4 (the blocker, a6) was recorded 2026-10-20 and imported 2026-11-14.
        let line = try KnowledgeFixtureTimeline.load("pt-provisioning-timeline")
        let blocker = try #require(Self.claims("a6", in: line))
        #expect(blocker.observedAt == KnowledgeFixtureTimeline.date("2026-10-20T13:00:00Z"))
        #expect(blocker.recordedAt == KnowledgeFixtureTimeline.date("2026-11-14T10:00:00Z"))

        let cutoff = KnowledgeFixtureTimeline.date("2026-10-25")
        let said = KnowledgeObservedTime.saidBy(cutoff, in: line.claims)
        #expect(said.contains { $0.id == blocker.id })
        // Known by the same day: the blocker had not been imported, so the reducer does not see it.
        let known = line.claims.filter { $0.recordedAt <= cutoff }
        #expect(!known.contains { $0.id == blocker.id })
    }

    @Test func saidByIsInclusiveAndExcludesLaterMeetings() throws {
        let line = try KnowledgeFixtureTimeline.load("pt-provisioning-timeline")
        let cutoff = KnowledgeFixtureTimeline.date("2026-10-15T13:00:00Z")
        let said = Set(KnowledgeObservedTime.saidBy(cutoff, in: line.claims).map(\.id))
        #expect(said.contains(try #require(line.assertions["a5"])))        // m3, 2026-10-15, inclusive
        #expect(!said.contains(try #require(line.assertions["a6"])))       // m4, 2026-10-20
        #expect(!said.contains(try #require(line.assertions["a8"])))       // m6, 2026-11-10
    }

    @Test func aClaimWithNoSourceTimeIsNeverSaidByAnyDate() {
        let unknown = KnowledgeTemporalClaim(
            id: UUID(), subjectID: UUID(), predicate: .hasStatus, modality: .agreed, validFrom: nil,
            recordedAt: Date(timeIntervalSince1970: 0))
        #expect(KnowledgeObservedTime.saidBy(.distantFuture, in: [unknown]).isEmpty)
        #expect(KnowledgeObservedTime.unplaced(in: [unknown]).count == 1)
    }

    @Test func theMovedDeadlineIsAnsweredFromWhatWasSaidByThen() throws {
        // en-moved-deadline: as of October 10 the due date said so far is October 16 (a3), not November 6 (a5).
        let line = try KnowledgeFixtureTimeline.load("en-moved-deadline")
        let said = KnowledgeObservedTime.saidBy(KnowledgeFixtureTimeline.date("2026-10-10"), in: line.claims)
        let ids = Set(said.map(\.id))
        #expect(ids.contains(try #require(line.assertions["a3"])))
        #expect(!ids.contains(try #require(line.assertions["a5"])))
        // The blocker (a4) was said on 2026-10-14 and imported on 2026-11-20: not said, not known, by October 10.
        #expect(!ids.contains(try #require(line.assertions["a4"])))
    }

    @Test func theTimelineKeepsSourceTimeAndRecordedTimeApartPerClaim() throws {
        let line = try KnowledgeFixtureTimeline.load("pt-provisioning-timeline")
        // The helper's snapshot dates both clocks with the meeting; give each fact its claim's own transaction time
        // (the meeting's import), so a swap of the two fields cannot pass.
        let recordedByFact = Dictionary(uniqueKeysWithValues: line.claims.map { ($0.id, $0.recordedAt) })
        let observedByFact = Dictionary(uniqueKeysWithValues: line.claims.map { ($0.id, $0.observedAt) })
        let facts = try line.snapshot.facts.map { fact in
            KnowledgeWikiSnapshot.Fact(
                id: fact.id, subjectID: fact.subjectID, predicate: fact.predicate, objectID: fact.objectID, value: fact.value,
                qualifiers: fact.qualifiers,
                source: .init(meetingID: fact.source.meetingID, recordedAt: try #require(recordedByFact[fact.id]),
                              observedAt: fact.source.observedAt, evidence: fact.source.evidence))
        }
        let snapshot = KnowledgeWikiSnapshot(revision: line.snapshot.revision, entities: line.snapshot.entities, facts: facts)
        let timeline = KnowledgeTimeline.build(pages: try KnowledgeWikiProjector.project(snapshot))
        let entries = timeline.periods.flatMap(\.entries) + timeline.undated
        #expect(entries.count == facts.count)
        for entry in entries {
            #expect(entry.recordedAt == recordedByFact[entry.factID])
            #expect(entry.observedAt == observedByFact[entry.factID] ?? nil)
        }
        // The late import: said 2026-10-20, recorded 2026-11-14.
        let blocker = try #require(line.assertions["a6"])
        let late = try #require(entries.first { $0.factID == blocker })
        #expect(late.observedAt == KnowledgeFixtureTimeline.date("2026-10-20T13:00:00Z"))
        #expect(late.recordedAt == KnowledgeFixtureTimeline.date("2026-11-14T10:00:00Z"))
        #expect(entries.contains { $0.observedAt != $0.recordedAt })
    }

    @Test func dayEndIsTheMidnightThatStartsTheNextUTCDayAndOnlyForDays() throws {
        let day = try #require(KnowledgeTemporalValue(text: "2026-10-20", precision: .day))
        #expect(KnowledgeObservedTime.dayEnd(day) == KnowledgeFixtureTimeline.date("2026-10-21T00:00:00Z"))
        let month = try #require(KnowledgeTemporalValue(text: "2026-10", precision: .month))
        #expect(KnowledgeObservedTime.dayEnd(month) == nil)
    }

    @Test func aMeetingInTheLastFractionOfADayIsInThatDayAndMidnightIsTheNext() throws {
        let line = try KnowledgeFixtureTimeline.load("pt-provisioning-timeline")
        let late = try #require(line.assertions["a1"]), midnight = try #require(line.assertions["a2"])
        let dayEnd = try #require(KnowledgeObservedTime.dayEnd(try #require(KnowledgeTemporalValue(text: "2026-08-17", precision: .day))))
        let overrides: [UUID: Date] = [late: dayEnd.addingTimeInterval(-0.5), midnight: dayEnd]
        var facts: [KnowledgeWikiSnapshot.Fact] = []
        for fact in line.snapshot.facts {
            guard let observed = overrides[fact.id] else {
                facts.append(fact)
                continue
            }
            let source = KnowledgeWikiSnapshot.Source(meetingID: fact.source.meetingID, recordedAt: fact.source.recordedAt,
                                                      observedAt: observed, evidence: fact.source.evidence)
            facts.append(KnowledgeWikiSnapshot.Fact(
                id: fact.id, subjectID: fact.subjectID, predicate: fact.predicate, objectID: fact.objectID, value: fact.value,
                qualifiers: fact.qualifiers, source: source))
        }
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: line.snapshot.entities, facts: facts)
        let restriction = KnowledgeObservedTime.restricting(try KnowledgeWikiProjector.project(snapshot), saidBefore: dayEnd)
        let kept = Set(restriction.pages.flatMap { $0.sections.flatMap(\.entries) }.map(\.fact.id))
        #expect(kept == [late])
        #expect(restriction.shown == 1 && restriction.hiddenLater == 8)
    }

    @Test func restrictingKeepsOnlyClaimsSaidByTheDayAndCountsEachClaimOnce() throws {
        let line = try KnowledgeFixtureTimeline.load("pt-provisioning-timeline")
        let pages = try KnowledgeWikiProjector.project(line.snapshot)
        let upper = try #require(KnowledgeObservedTime.dayEnd(try #require(KnowledgeTemporalValue(text: "2026-10-20", precision: .day))))
        let restriction = KnowledgeObservedTime.restricting(pages, saidBefore: upper)
        // m1 to m4 (a1 to a6) were said by then; m5 (a7) and m6 (a8, a9) later. A claim on two pages counts once.
        #expect(restriction.shown == 6 && restriction.hiddenLater == 3 && restriction.hiddenUnplaced == 0)
        let kept = Set(restriction.pages.flatMap { $0.sections.flatMap(\.entries) }.map(\.fact.id))
        let expected = Set(try ["a1", "a2", "a3", "a4", "a5", "a6"].map { try #require(line.assertions[$0]) })
        #expect(kept == expected)
        #expect(restriction.pages.allSatisfy { page in page.sections.allSatisfy { !$0.entries.isEmpty } })
        // Before anything was said no page is left, and the same counts say why.
        let none = KnowledgeObservedTime.restricting(pages, saidBefore: KnowledgeFixtureTimeline.date("2026-09-01"))
        #expect(none.pages.isEmpty && none.shown == 0 && none.hiddenLater == 9)
    }

    @Test func restrictingDropsGeneratedNarrativesAndLeavesUnknownSourceTimesOut() throws {
        let line = try KnowledgeFixtureTimeline.load("pt-provisioning-timeline")
        let project = try #require(line.entities["e1"]), first = try #require(line.assertions["a1"])
        // a1's meeting date is unknown; every other claim keeps its own.
        var facts: [KnowledgeWikiSnapshot.Fact] = []
        for fact in line.snapshot.facts {
            guard fact.id == first else {
                facts.append(fact)
                continue
            }
            let source = KnowledgeWikiSnapshot.Source(meetingID: fact.source.meetingID, recordedAt: fact.source.recordedAt,
                                                      evidence: fact.source.evidence)
            facts.append(KnowledgeWikiSnapshot.Fact(
                id: fact.id, subjectID: fact.subjectID, predicate: fact.predicate, objectID: fact.objectID, value: fact.value,
                qualifiers: fact.qualifiers, source: source))
        }
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: line.snapshot.entities, facts: facts)
        let narrative = KnowledgeWikiNarrative(entityID: project, paragraphs: [
            .init(text: "The environment provisioning project.", assertionIDs: [first])])
        let pages = try KnowledgeWikiProjector.project(snapshot, narratives: [narrative])
        #expect(pages.first { $0.entity.id == project }?.narrative != nil)
        let restriction = KnowledgeObservedTime.restricting(pages, saidBefore: .distantFuture)
        #expect(restriction.hiddenUnplaced == 1 && restriction.hiddenLater == 0 && restriction.shown == 8)
        #expect(restriction.pages.allSatisfy { $0.narrative == nil })
        #expect(!restriction.pages.flatMap { $0.sections.flatMap(\.entries) }.contains { $0.fact.id == first })
    }

    @Test func aSnapshotStoredBeforeSourceTimeExistedStillDecodes() throws {
        let source = KnowledgeWikiSnapshot.Source(meetingID: UUID(), recordedAt: Date(timeIntervalSince1970: 10), evidence: [])
        #expect(source.observedAt == nil)
        let data = try JSONEncoder().encode(source)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["observedAt"] == nil)
        #expect(try JSONDecoder().decode(KnowledgeWikiSnapshot.Source.self, from: data) == source)
    }
}

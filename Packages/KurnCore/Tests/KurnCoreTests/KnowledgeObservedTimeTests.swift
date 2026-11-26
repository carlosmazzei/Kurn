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

    @Test func aSnapshotStoredBeforeSourceTimeExistedStillDecodes() throws {
        let source = KnowledgeWikiSnapshot.Source(meetingID: UUID(), recordedAt: Date(timeIntervalSince1970: 10), evidence: [])
        #expect(source.observedAt == nil)
        let data = try JSONEncoder().encode(source)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["observedAt"] == nil)
        #expect(try JSONDecoder().decode(KnowledgeWikiSnapshot.Source.self, from: data) == source)
    }
}

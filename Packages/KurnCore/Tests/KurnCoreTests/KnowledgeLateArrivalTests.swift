import Foundation
import Testing
@testable import KurnCore

/// K3.5: a late arrival recomputes only the valid interval it affects.
struct KnowledgeLateArrivalTests {
    private typealias Timeline = KnowledgeFixtureTimeline

    @Test func theBlockerImportedWeeksLateRevisesTheProjectFromItsStatedDay() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let project = try #require(line.entities["e1"])
        let revisions = KnowledgeLateArrival.revisions(of: project, claims: line.claims)
        // The metric, the due date and the status were each recorded on the day
        // they state; only the blocker (said Oct 20, imported Nov 14) is late.
        #expect(revisions.count == 1)
        let late = try #require(revisions.first)
        #expect(late.arrivedAt == Timeline.date("2026-11-14T10:00:00Z"))
        #expect(late.claimIDs == [line.assertions["a6"]].compactMap { $0 })
        #expect(late.affectedFrom == Timeline.date("2026-10-20T00:00:00Z"))
        // It grows certain after Oct 20 and the November status changes nothing
        // about it, so the whole change is one stretch that still lasts.
        #expect(late.segments.count == 1 && late.segments.first?.upper == nil)
        let change = try #require(late.segments.first?.comparison.changes.first { $0.kind != .unchanged })
        #expect(change.kind == .started && change.predicate == .blocks && change.direction == .incoming)
        #expect(late.segments.first?.comparison.changes.filter { $0.kind != .unchanged }.count == 1)
    }

    @Test func entitiesWithNothingLateHaveNoRevisions() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        for ref in ["e2", "e3", "e4", "e5"] {
            let entity = try #require(line.entities[ref])
            #expect(KnowledgeLateArrival.revisions(of: entity, claims: line.claims).isEmpty)
        }
    }

    // MARK: - Synthetic

    private static let subject = UUID()

    private static func status(_ value: String, from day: String, recorded: String) -> KnowledgeTemporalClaim {
        KnowledgeTemporalClaim(id: UUID(), subjectID: subject, predicate: .hasStatus, value: .enumeration(value),
                               modality: .reported, validFrom: Timeline.day(day), recordedAt: Timeline.date(recorded))
    }

    @Test func aLateStatusSplitsWhereItGrowsCertain() throws {
        let open = Self.status("open", from: "2026-03-01", recorded: "2026-03-01")
        let blocked = Self.status("blocked", from: "2026-04-01", recorded: "2026-06-01")
        let late = try #require(KnowledgeLateArrival.recompute(entityID: Self.subject, arrivedAt: blocked.recordedAt,
                                                              claims: [blocked, open]))
        #expect(late.segments.map(\.lower) == [Timeline.date("2026-04-01T00:00:00Z"), Timeline.date("2026-04-02T00:00:00Z")])
        #expect(late.segments.map(\.upper) == [Timeline.date("2026-04-02T00:00:00Z"), nil])
        // During April 1 the new status may already hold; from April 2 it replaced open.
        let first = try #require(late.segments.first?.comparison.changes.map(\.kind))
        #expect(first == [.started, .unchanged])
        #expect(late.segments.last?.comparison.changes.map(\.kind) == [.changed])
        #expect(late.segments.last?.comparison.changes.first?.before?.value == .enumeration("open"))
    }

    @Test func nothingIsLateWithoutEarlierKnowledgeOrWithoutAChange() throws {
        let first = Self.status("open", from: "2026-03-01", recorded: "2026-06-01")
        #expect(KnowledgeLateArrival.recompute(entityID: Self.subject, arrivedAt: first.recordedAt, claims: [first]) == nil)
        let earlier = Self.status("open", from: "2026-03-01", recorded: "2026-03-01")
        let restated = Self.status("open", from: "2026-03-01", recorded: "2026-06-01")
        #expect(KnowledgeLateArrival.recompute(entityID: Self.subject, arrivedAt: restated.recordedAt,
                                               claims: [earlier, restated]) == nil)
        #expect(KnowledgeLateArrival.recompute(entityID: Self.subject, arrivedAt: Timeline.date("2026-07-01"),
                                               claims: [earlier]) == nil)
    }

    @Test func aChangeStatedForItsOwnRecordingDayIsNotLate() throws {
        let open = Self.status("open", from: "2026-03-01", recorded: "2026-03-01")
        let sameDay = Self.status("ready", from: "2026-05-01", recorded: "2026-05-01T18:00:00Z")
        #expect(KnowledgeLateArrival.recompute(entityID: Self.subject, arrivedAt: sameDay.recordedAt,
                                               claims: [open, sameDay]) == nil)
        #expect(KnowledgeLateArrival.revisions(of: Self.subject, claims: [open, sameDay]).isEmpty)
    }

    @Test func revisionsDoNotDependOnClaimOrder() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let project = try #require(line.entities["e1"])
        #expect(KnowledgeLateArrival.revisions(of: project, claims: line.claims)
            == KnowledgeLateArrival.revisions(of: project, claims: line.claims.reversed()))
    }
}

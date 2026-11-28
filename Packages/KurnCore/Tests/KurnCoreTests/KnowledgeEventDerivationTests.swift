import Foundation
import Testing
@testable import KurnCore

/// K7.2: the dated changes of an entity derived from the claims known at a transaction time.
struct KnowledgeEventDerivationTests {
    private typealias Timeline = KnowledgeFixtureTimeline
    private static func date(_ text: String) -> Date { Timeline.date(text) }
    private static func day(_ text: String) -> KnowledgeTemporalValue { Timeline.day(text) }
    private static let later = date("2026-12-31")

    private struct Row: Equatable {
        let kind: KnowledgeEventKind
        let detail: String
        let previous: String?
    }

    private static func rows(_ events: [KnowledgeEventDerivation.Event]) -> [Row] {
        events.map { Row(kind: $0.kind, detail: $0.detail, previous: $0.previous) }
    }

    @Test func aMovedDeadlineAndAHandoverAreDatedChangesInStatedOrder() throws {
        let line = try Timeline.load("en-moved-deadline")
        let action = try #require(line.entities["e1"])
        let maria = try #require(line.entities["e2"]).uuidString, lee = try #require(line.entities["e4"]).uuidString
        let events = KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.later, claims: line.claims)
        #expect(Self.rows(events) == [
            Row(kind: .assigned, detail: maria, previous: nil),
            Row(kind: .dueDateChanged, detail: "2026-10-09", previous: nil),
            Row(kind: .dueDateChanged, detail: "2026-10-16", previous: "2026-10-09"),
            Row(kind: .assigned, detail: lee, previous: maria),
            Row(kind: .dueDateChanged, detail: "2026-11-06", previous: "2026-10-16")
        ])
        #expect(events.map(\.occurredAt) == [Self.day("2026-10-05"), Self.day("2026-10-05"), Self.day("2026-10-08"),
                                              Self.day("2026-10-20"), Self.day("2026-10-20")])
        #expect(events[2].claimIDs == [try #require(line.assertions["a3"])])
        #expect(events.allSatisfy { !$0.isLate })
    }

    @Test func aDecisionsLifecycleBecomesStatusChangesAndASupersession() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let thread = try #require(line.entities["e2"])
        let events = KnowledgeEventDerivation.derive(entityID: thread, lifecycle: .decision, knownAt: Self.later, claims: line.claims)
        #expect(Self.rows(events) == [
            Row(kind: .statusChanged, detail: "proposed", previous: nil),
            Row(kind: .statusChanged, detail: "approved", previous: "proposed"),
            Row(kind: .statusChanged, detail: "revised", previous: "approved"),
            Row(kind: .superseded, detail: "superseded", previous: "revised")
        ])
        #expect(events.last?.claimIDs == [try #require(line.assertions["a8"])])
        // Known before the superseding meeting was imported, the last event does not exist yet.
        let earlier = KnowledgeEventDerivation.derive(entityID: thread, lifecycle: .decision,
                                                      knownAt: Self.date("2026-11-10T13:00:00Z"), claims: line.claims)
        #expect(earlier.count == 3 && earlier.allSatisfy { $0.kind == .statusChanged })
    }

    @Test func aRetractedClaimDropsItsEventsOnTheNextDerivation() throws {
        let line = try Timeline.load("en-moved-deadline")
        let action = try #require(line.entities["e1"])
        let retracted = try #require(line.assertions["a5"])
        let claims = line.claims.map { claim in
            claim.id == retracted
                ? KnowledgeTemporalClaim(id: claim.id, subjectID: claim.subjectID, predicate: claim.predicate,
                                         objectID: claim.objectID, value: claim.value, polarity: claim.polarity,
                                         modality: claim.modality, validFrom: claim.validFrom, recordedAt: claim.recordedAt,
                                         retractedAt: Self.date("2026-11-25"), observedAt: claim.observedAt)
                : claim
        }
        let before = KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.date("2026-11-21"), claims: claims)
        let after = KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.later, claims: claims)
        #expect(before.contains { $0.detail == "2026-11-06" })
        #expect(!after.contains { $0.detail == "2026-11-06" })
        #expect(after.count == before.count - 1)
    }

    @Test func theOutputDoesNotDependOnTheOrderOfTheClaims() throws {
        let line = try Timeline.load("en-moved-deadline")
        let action = try #require(line.entities["e1"])
        let forward = KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.later, claims: line.claims)
        let backward = KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.later,
                                                       claims: Array(line.claims.reversed()))
        #expect(forward == backward)
        #expect(Set(forward.map(\.key)).count == forward.count)
    }

    @Test func tentativeNegatedAndUndatedClaimsStateNoChange() {
        let action = UUID(), person = UUID(), recorded = Self.date("2026-01-01")
        func due(_ text: String, modality: KnowledgeModality = .agreed, polarity: KnowledgePolarity = .positive,
                 from: KnowledgeTemporalValue? = Self.day("2026-02-01")) -> KnowledgeTemporalClaim {
            KnowledgeTemporalClaim(id: UUID(), subjectID: action, predicate: .dueOn,
                                   value: .date(Self.day(text)), polarity: polarity, modality: modality,
                                   validFrom: from, recordedAt: recorded)
        }
        let claims = [
            due("2026-03-01", modality: .proposed), due("2026-03-02", modality: .hypothetical),
            due("2026-03-03", polarity: .negative), due("2026-03-04", from: nil),
            KnowledgeTemporalClaim(id: UUID(), subjectID: action, predicate: .assignedTo, objectID: person, modality: .disputed,
                                   validFrom: Self.day("2026-02-01"), recordedAt: recorded)
        ]
        #expect(KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.later, claims: claims).isEmpty)
    }

    @Test func ownershipStatedFromEitherSideOfOneAssigneeIsOneChange() {
        let action = UUID(), person = UUID(), recorded = Self.date("2026-01-01"), start = Self.day("2026-02-01")
        let assigned = KnowledgeTemporalClaim(id: UUID(), subjectID: action, predicate: .assignedTo, objectID: person,
                                              modality: .agreed, validFrom: start, recordedAt: recorded)
        let owns = KnowledgeTemporalClaim(id: UUID(), subjectID: person, predicate: .owns, objectID: action,
                                          modality: .agreed, validFrom: start, recordedAt: recorded)
        let events = KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.later, claims: [owns, assigned])
        #expect(events.count == 1)
        #expect(events.first?.claimIDs == [assigned.id, owns.id].sorted { $0.uuidString < $1.uuidString })
        #expect(events.first?.detail == person.uuidString)
    }

    @Test func aChangeStatedForAnEarlierDayThanItsRecordingIsLate() {
        let action = UUID()
        func completed(recordedOn recorded: String) -> [KnowledgeEventDerivation.Event] {
            let claim = KnowledgeTemporalClaim(id: UUID(), subjectID: action, predicate: .hasStatus,
                                               value: .enumeration("completed"), modality: .agreed,
                                               validFrom: Self.day("2026-10-01"), recordedAt: Self.date(recorded))
            return KnowledgeEventDerivation.derive(entityID: action, lifecycle: .action, knownAt: Self.later, claims: [claim])
        }
        #expect(completed(recordedOn: "2026-11-14T10:00:00Z").first?.isLate == true)
        #expect(completed(recordedOn: "2026-10-01T10:00:00Z").first?.isLate == false)
    }

    @Test func anEntityWithoutALifecycleHasNoStatusEvents() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let project = try #require(line.entities["e1"])
        let events = KnowledgeEventDerivation.derive(entityID: project, lifecycle: nil, knownAt: Self.later, claims: line.claims)
        #expect(Self.rows(events) == [Row(kind: .dueDateChanged, detail: "2026-10", previous: nil)])
    }

    @Test func lifecycleOrderSurvivesAMonthStatedCompletionAfterADayStatedCommitment() throws {
        let item = UUID(), recorded = Self.date("2026-01-01")
        func status(_ raw: String, _ stated: KnowledgeTemporalValue) -> KnowledgeTemporalClaim {
            KnowledgeTemporalClaim(id: UUID(), subjectID: item, predicate: .hasStatus, value: .enumeration(raw),
                                   modality: .agreed, validFrom: stated, recordedAt: recorded)
        }
        let november = try #require(KnowledgeTemporalValue(text: "2026-11", precision: .month))
        let claims = [status("completed", november), status("committed", Self.day("2026-11-03"))]
        let events = KnowledgeEventDerivation.derive(entityID: item, lifecycle: .action, knownAt: Self.later, claims: claims)
        #expect(Self.rows(events) == [Row(kind: .statusChanged, detail: "committed", previous: nil),
                                      Row(kind: .statusChanged, detail: "completed", previous: "committed")])
    }

    @Test func aLaterConfirmationDoesNotMakeTheOriginalChangeLate() {
        let action = UUID(), due = Self.day("2026-10-09")
        func claim(recorded: String) -> KnowledgeTemporalClaim {
            KnowledgeTemporalClaim(id: UUID(), subjectID: action, predicate: .dueOn, value: .date(due), modality: .agreed,
                                   validFrom: Self.day("2026-10-01"), recordedAt: Self.date(recorded))
        }
        let events = KnowledgeEventDerivation.derive(
            entityID: action, lifecycle: .action, knownAt: Self.later,
            claims: [claim(recorded: "2026-10-01T10:00:00Z"), claim(recorded: "2026-10-02T10:00:00Z")])
        #expect(events.count == 1)
        #expect(events.first?.recordedAt == Self.date("2026-10-01T10:00:00Z"))
        #expect(events.first?.isLate == false)
    }

    @Test func ownersStatedForTheSameDayAreNotAHandoverAndACoverStatesNoChange() {
        let action = UUID(), first = UUID(), second = UUID(), cover = UUID(), recorded = Self.date("2026-01-01")
        func assigned(_ owner: UUID, from: String, until: String? = nil) -> KnowledgeTemporalClaim {
            KnowledgeTemporalClaim(id: UUID(), subjectID: action, predicate: .assignedTo, objectID: owner, modality: .agreed,
                                   validFrom: Self.day(from), validTo: until.map(Self.day), recordedAt: recorded)
        }
        let events = KnowledgeEventDerivation.derive(
            entityID: action, lifecycle: .action, knownAt: Self.later,
            claims: [assigned(first, from: "2026-02-01"), assigned(second, from: "2026-02-01"),
                     assigned(cover, from: "2026-03-01", until: "2026-03-08")])
        #expect(events.count == 2)
        #expect(Set(events.map(\.detail)) == [first.uuidString, second.uuidString])
        #expect(events.allSatisfy { $0.previous == nil })
    }

    @Test func anEarlierStartLearnedLaterMakesTheChangeLate() {
        let action = UUID(), due = Self.day("2026-10-09")
        func claim(from: String, recorded: String) -> KnowledgeTemporalClaim {
            KnowledgeTemporalClaim(id: UUID(), subjectID: action, predicate: .dueOn, value: .date(due), modality: .agreed,
                                   validFrom: Self.day(from), recordedAt: Self.date(recorded))
        }
        let events = KnowledgeEventDerivation.derive(
            entityID: action, lifecycle: .action, knownAt: Self.later,
            claims: [claim(from: "2026-10-05", recorded: "2026-09-28T10:00:00Z"),
                     claim(from: "2026-10-01", recorded: "2026-10-03T10:00:00Z")])
        #expect(events.count == 1)
        #expect(events.first?.occurredAt == Self.day("2026-10-01"))
        #expect(events.first?.recordedAt == Self.date("2026-10-03T10:00:00Z"))
        #expect(events.first?.isLate == true)
    }
}

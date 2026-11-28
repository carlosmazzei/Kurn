//
//  KnowledgeEventDerivation.swift
//  KurnCore
//
//  K7.2: the dated changes of one entity, derived from the claims known at a
//  transaction time. Pure, Foundation-only and deterministic: the lifecycle
//  machines (K3.2) give status changes, reopenings and supersessions, and the
//  stated `dueOn` and owner claims give due-date and assignment changes, in
//  stated order and never by recording order. An event names the claims that
//  state it; it is a projection, never evidence, so a retracted claim drops its
//  events the next time the derivation runs. The store write (a later step)
//  compares this output with what it holds and replaces the difference.
//

import Foundation

public enum KnowledgeEventDerivation {
    /// One dated change of an entity.
    public struct Event: Codable, Equatable, Sendable {
        public let kind: KnowledgeEventKind
        public let entityID: UUID
        /// When it happened, as stated and at its stated precision.
        public let occurredAt: KnowledgeTemporalValue?
        /// The claims that state it, sorted by ID; the first names the change.
        public let claimIDs: [UUID]
        /// What it became: a status raw value, a due date's text or an owner's entity ID.
        public let detail: String
        /// What it replaced, when something did.
        public let previous: String?
        /// Transaction time at which the change was first known: the earliest claim that states its start, so a later
        /// confirmation never makes it look late and an earlier start learned later still does.
        public let recordedAt: Date
        /// True when the change starts before the UTC day it was recorded on:
        /// knowledge that arrived after the days it concerns (K3.5).
        public let isLate: Bool
        /// Identity of the event across recomputations: kind, entity and claims.
        public var key: String {
            ([kind.rawValue, entityID.uuidString] + claimIDs.map(\.uuidString)).joined(separator: "|")
        }
    }

    /// The events of `entityID` known at `knownAt`, ordered by stated start (undated last), then kind and key.
    public static func derive(entityID: UUID, lifecycle: KnowledgeLifecycle?, knownAt: Date,
                              claims: [KnowledgeTemporalClaim]) -> [Event] {
        let known = claims.filter { $0.recordedAt <= knownAt && ($0.retractedAt.map { knownAt < $0 } ?? true) }
        let recorded = Dictionary(known.map { ($0.id, $0.recordedAt) }, uniquingKeysWith: max)
        var entries = statusEvents(entityID: entityID, lifecycle: lifecycle, knownAt: knownAt, claims: known, recorded: recorded)
        entries += dueDateEvents(entityID: entityID, claims: known, recorded: recorded)
        entries += assignmentEvents(entityID: entityID, claims: known, recorded: recorded)
        return entries.sorted(by: ordered).map(\.event)
    }

    /// An event with where it sorts. A lifecycle transition keeps the machine's order even where the machine
    /// placed a month-stated completion after a day-stated commitment, so its sort date never moves backwards.
    private struct Entry {
        let event: Event
        let sortDate: Date?
        let group: Int
        let sequence: Int
    }

    private static func ordered(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.sortDate != rhs.sortDate {
            guard let left = lhs.sortDate else { return false }
            guard let right = rhs.sortDate else { return true }
            return left < right
        }
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return (lhs.event.kind.rawValue, lhs.event.key) < (rhs.event.kind.rawValue, rhs.event.key)
    }

    // swiftlint:disable:next function_parameter_count
    private static func make(_ kind: KnowledgeEventKind, entityID: UUID, stated: KnowledgeTemporalValue?, claimIDs: [UUID],
                             detail: String, previous: String?, recorded: [UUID: Date],
                             anchorIDs: [UUID]? = nil) -> Event {
        let ids = claimIDs.sorted { $0.uuidString < $1.uuidString }
        let recordedAt = (anchorIDs ?? ids).compactMap { recorded[$0] }.min() ?? .distantPast
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let late = stated?.bounds.map { $0.lower < utc.startOfDay(for: recordedAt) } ?? false
        return Event(kind: kind, entityID: entityID, occurredAt: stated, claimIDs: ids, detail: detail, previous: previous,
                     recordedAt: recordedAt, isLate: late)
    }

    private static func statusEvents(entityID: UUID, lifecycle: KnowledgeLifecycle?, knownAt: Date,
                                     claims: [KnowledgeTemporalClaim], recorded: [UUID: Date]) -> [Entry] {
        guard let lifecycle else { return [] }
        var latest: Date?
        return lifecycle.project(entityID: entityID, knownAt: knownAt, claims: claims).transitions.enumerated().map { index, transition in
            let kind: KnowledgeEventKind = switch transition.status {
            case .reopened: .reopened
            case .superseded: .superseded
            default: .statusChanged
            }
            let event = make(kind, entityID: entityID, stated: transition.stated, claimIDs: transition.claimIDs,
                             detail: transition.status.rawValue, previous: transition.from?.rawValue, recorded: recorded)
            if let lower = transition.stated.bounds?.lower { latest = max(latest ?? lower, lower) }
            return Entry(event: event, sortDate: latest, group: 0, sequence: index)
        }
    }

    /// An established, positive, dated claim with no stated end: what a change can be built on. A claim with a
    /// stated end (a week's cover) is a temporary holding, not a handover or a new date, so it states no change.
    private static func firm(_ claim: KnowledgeTemporalClaim) -> Bool {
        claim.polarity == .positive && !KnowledgeTemporalReducer.tentative.contains(claim.modality)
            && claim.validFrom?.bounds != nil && claim.validTo == nil
    }

    private struct Change {
        let stated: KnowledgeTemporalValue
        let detail: String
        var claimIDs: [UUID]
        /// The claims that state the chosen start: the change was first known when the earliest of them was recorded.
        var anchorIDs: [UUID]
        let previous: String?
    }

    /// Consecutive statements of the same value are one change; the earliest stated start names it. A change
    /// names what it replaced only when its stated start is wholly after the previous change's: starts that
    /// overlap are a conflict the temporal reducer reports, not an order this derivation may invent.
    private static func changes(_ steps: [(stated: KnowledgeTemporalValue, detail: String, claimID: UUID)]) -> [Change] {
        let sorted = steps.sorted {
            let (left, right) = ($0.stated.bounds?.lower ?? .distantPast, $1.stated.bounds?.lower ?? .distantPast)
            return left != right ? left < right : $0.claimID.uuidString < $1.claimID.uuidString
        }
        var result: [Change] = []
        for step in sorted {
            let bounds = step.stated.bounds
            if let last = result.last, last.detail == step.detail {
                result[result.count - 1].claimIDs.append(step.claimID)
                if step.stated == last.stated { result[result.count - 1].anchorIDs.append(step.claimID) }
                continue
            }
            let replaced = result.last.flatMap { last in
                (last.stated.bounds?.upper ?? .distantFuture) <= (bounds?.lower ?? .distantPast) ? last.detail : nil
            }
            result.append(Change(stated: step.stated, detail: step.detail, claimIDs: [step.claimID], anchorIDs: [step.claimID],
                                 previous: replaced))
        }
        return result
    }

    private static func dueDateEvents(entityID: UUID, claims: [KnowledgeTemporalClaim], recorded: [UUID: Date]) -> [Entry] {
        let steps = claims.compactMap { claim -> (stated: KnowledgeTemporalValue, detail: String, claimID: UUID)? in
            guard claim.subjectID == entityID, claim.predicate == .dueOn, firm(claim),
                  case let .date(due) = claim.value, let stated = claim.validFrom else { return nil }
            return (stated, due.text, claim.id)
        }
        return changes(steps).enumerated().map { index, change in
            let event = make(.dueDateChanged, entityID: entityID, stated: change.stated, claimIDs: change.claimIDs,
                             detail: change.detail, previous: change.previous, recorded: recorded,
                             anchorIDs: change.anchorIDs)
            return Entry(event: event, sortDate: change.stated.bounds?.lower, group: 2, sequence: index)
        }
    }

    /// Owners from `assignedTo` (action → person) and `owns` (person → action) fold into one sequence.
    private static func assignmentEvents(entityID: UUID, claims: [KnowledgeTemporalClaim], recorded: [UUID: Date]) -> [Entry] {
        let steps = claims.compactMap { claim -> (stated: KnowledgeTemporalValue, detail: String, claimID: UUID)? in
            guard firm(claim), let stated = claim.validFrom else { return nil }
            if claim.predicate == .assignedTo, claim.subjectID == entityID, let owner = claim.objectID {
                return (stated, owner.uuidString, claim.id)
            }
            if claim.predicate == .owns, claim.objectID == entityID {
                return (stated, claim.subjectID.uuidString, claim.id)
            }
            return nil
        }
        return changes(steps).enumerated().map { index, change in
            let event = make(.assigned, entityID: entityID, stated: change.stated, claimIDs: change.claimIDs,
                             detail: change.detail, previous: change.previous, recorded: recorded,
                             anchorIDs: change.anchorIDs)
            return Entry(event: event, sortDate: change.stated.bounds?.lower, group: 1, sequence: index)
        }
    }
}

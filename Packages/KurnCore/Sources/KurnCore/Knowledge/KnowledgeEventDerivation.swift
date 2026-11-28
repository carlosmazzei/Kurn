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
        /// Transaction time of the latest claim among `claimIDs`.
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
        var events = statusEvents(entityID: entityID, lifecycle: lifecycle, knownAt: knownAt, claims: known, recorded: recorded)
        events += dueDateEvents(entityID: entityID, claims: known)
        events += assignmentEvents(entityID: entityID, claims: known)
        return events.sorted(by: ordered)
    }

    private static func ordered(_ lhs: Event, _ rhs: Event) -> Bool {
        let left = lhs.occurredAt?.bounds?.lower, right = rhs.occurredAt?.bounds?.lower
        if left != right {
            guard let left else { return false }
            guard let right else { return true }
            return left < right
        }
        return (lhs.kind.rawValue, lhs.key) < (rhs.kind.rawValue, rhs.key)
    }

    // swiftlint:disable:next function_parameter_count
    private static func make(_ kind: KnowledgeEventKind, entityID: UUID, stated: KnowledgeTemporalValue?, claimIDs: [UUID],
                             detail: String, previous: String?, recorded: [UUID: Date]) -> Event {
        let ids = claimIDs.sorted { $0.uuidString < $1.uuidString }
        let recordedAt = ids.compactMap { recorded[$0] }.max() ?? .distantPast
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let late = stated?.bounds.map { $0.lower < utc.startOfDay(for: recordedAt) } ?? false
        return Event(kind: kind, entityID: entityID, occurredAt: stated, claimIDs: ids, detail: detail, previous: previous,
                     recordedAt: recordedAt, isLate: late)
    }

    private static func statusEvents(entityID: UUID, lifecycle: KnowledgeLifecycle?, knownAt: Date,
                                     claims: [KnowledgeTemporalClaim], recorded: [UUID: Date]) -> [Event] {
        guard let lifecycle else { return [] }
        return lifecycle.project(entityID: entityID, knownAt: knownAt, claims: claims).transitions.map { transition in
            let kind: KnowledgeEventKind = switch transition.status {
            case .reopened: .reopened
            case .superseded: .superseded
            default: .statusChanged
            }
            return make(kind, entityID: entityID, stated: transition.stated, claimIDs: transition.claimIDs,
                        detail: transition.status.rawValue, previous: transition.from?.rawValue, recorded: recorded)
        }
    }

    /// An established, positive, dated claim: what a change can be built on.
    private static func firm(_ claim: KnowledgeTemporalClaim) -> Bool {
        claim.polarity == .positive && !KnowledgeTemporalReducer.tentative.contains(claim.modality)
            && claim.validFrom?.bounds != nil
    }

    /// Consecutive statements of the same value are one change; the earliest stated start names it.
    private struct Change {
        let stated: KnowledgeTemporalValue
        let detail: String
        var claimIDs: [UUID]
        let previous: String?
    }

    private static func changes(_ steps: [(stated: KnowledgeTemporalValue, detail: String, claimID: UUID)]) -> [Change] {
        let sorted = steps.sorted {
            let (left, right) = ($0.stated.bounds?.lower ?? .distantPast, $1.stated.bounds?.lower ?? .distantPast)
            return left != right ? left < right : $0.claimID.uuidString < $1.claimID.uuidString
        }
        var result: [Change] = []
        for step in sorted {
            if let last = result.last, last.detail == step.detail {
                result[result.count - 1].claimIDs.append(step.claimID)
            } else {
                result.append(Change(stated: step.stated, detail: step.detail, claimIDs: [step.claimID], previous: result.last?.detail))
            }
        }
        return result
    }

    private static func dueDateEvents(entityID: UUID, claims: [KnowledgeTemporalClaim]) -> [Event] {
        let steps = claims.compactMap { claim -> (stated: KnowledgeTemporalValue, detail: String, claimID: UUID)? in
            guard claim.subjectID == entityID, claim.predicate == .dueOn, firm(claim),
                  case let .date(due) = claim.value, let stated = claim.validFrom else { return nil }
            return (stated, due.text, claim.id)
        }
        return changes(steps).map { change in
            make(.dueDateChanged, entityID: entityID, stated: change.stated, claimIDs: change.claimIDs,
                 detail: change.detail, previous: change.previous, recorded: recordedDates(claims))
        }
    }

    /// Owners from `assignedTo` (action → person) and `owns` (person → action) fold into one sequence.
    private static func assignmentEvents(entityID: UUID, claims: [KnowledgeTemporalClaim]) -> [Event] {
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
        return changes(steps).map { change in
            make(.assigned, entityID: entityID, stated: change.stated, claimIDs: change.claimIDs,
                 detail: change.detail, previous: change.previous, recorded: recordedDates(claims))
        }
    }

    private static func recordedDates(_ claims: [KnowledgeTemporalClaim]) -> [UUID: Date] {
        Dictionary(claims.map { ($0.id, $0.recordedAt) }, uniquingKeysWith: max)
    }
}

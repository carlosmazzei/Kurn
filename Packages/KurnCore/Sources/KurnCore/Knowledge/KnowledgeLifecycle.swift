//
//  KnowledgeLifecycle.swift
//  KurnCore
//
//  K3.2: decision, action and risk state machines as projections of stated
//  status changes (spec §5.3, CLAUDE.md "Knowledge Engine decisions"). A status
//  is never stored as the latest mention: the transitions are rebuilt from the
//  claims known at a transaction time, ordered by what they state (valid time),
//  and checked against the machine. Where stated precision cannot order two
//  changes ("completed in November", "reopened on the 12th"), the machine may:
//  a reopening is evidence that the completion came first. Nothing is dropped —
//  a transition the machine does not allow, or an order neither the dates nor
//  the machine decide, is surfaced as an anomaly.
//

import Foundation

public enum KnowledgeLifecycle: String, Codable, Sendable, CaseIterable {
    case decision, action, risk

    public init?(entityKind: KnowledgeEntityKind) {
        switch entityKind {
        case .decisionThread: self = .decision
        case .actionItem: self = .action
        case .risk: self = .risk
        default: return nil
        }
    }

    /// Every status this machine knows; any other status is out of vocabulary.
    public var statuses: Set<KnowledgeStatus> {
        Set(transitions.keys.compactMap { $0 }).union(transitions.values.flatMap { $0 })
    }

    /// Whether `status` may follow `previous` (nil: the first status known).
    public func allows(from previous: KnowledgeStatus?, to status: KnowledgeStatus) -> Bool {
        transitions[previous]?.contains(status) ?? false
    }

    private var transitions: [KnowledgeStatus?: Set<KnowledgeStatus>] {
        switch self {
        case .decision:
            [nil: [.proposed, .approved, .rejected, .deferred],
             .proposed: [.approved, .rejected, .deferred],
             .deferred: [.proposed, .approved, .rejected],
             .rejected: [.proposed],
             .approved: [.revised, .superseded, .revoked],
             .revised: [.superseded, .revoked]]
        case .action:
            [nil: [.proposed, .committed, .inProgress, .completed, .cancelled],
             .proposed: [.committed, .cancelled],
             .committed: [.inProgress, .completed, .cancelled],
             .inProgress: [.completed, .cancelled],
             .completed: [.reopened],
             .cancelled: [.reopened],
             .reopened: [.committed, .inProgress, .completed, .cancelled]]
        case .risk:
            [nil: [.identified, .mitigated, .accepted, .closed],
             .identified: [.mitigated, .accepted, .closed],
             .mitigated: [.closed, .reopened],
             .accepted: [.closed, .reopened],
             .closed: [.reopened],
             .reopened: [.mitigated, .accepted, .closed]]
        }
    }
}

public struct KnowledgeLifecycleProjection: Codable, Equatable, Sendable {
    /// What decided a transition's place in the sequence.
    public enum OrderBasis: String, Codable, Sendable {
        /// Its stated date is wholly after the previous transition's.
        case statedTime = "stated_time"
        /// The dates overlap; only one order is a valid path through the machine.
        case lifecycle
        /// The dates overlap and the machine allows several orders (or the
        /// group is too large to search); the earliest-dated valid one is kept.
        case ambiguous
        /// The dates overlap and no order is a valid path; date order is kept.
        case unresolved
    }

    public struct Transition: Codable, Equatable, Sendable {
        public let status: KnowledgeStatus
        public let from: KnowledgeStatus?
        public let stated: KnowledgeTemporalValue
        public let orderBasis: OrderBasis
        /// Every claim stating this change, sorted by ID.
        public let claimIDs: [UUID]
    }

    public enum AnomalyCode: String, Codable, Sendable {
        case invalidTransition = "invalid_transition"
        case ambiguousOrder = "ambiguous_order"
        case unresolvedOrder = "unresolved_order"
        case outOfVocabulary = "out_of_vocabulary"
    }

    public struct Anomaly: Codable, Equatable, Sendable {
        public let code: AnomalyCode
        public let claimIDs: [UUID]
    }

    /// A known claim about the status that is not a transition.
    public enum SetAsideReason: String, Codable, Sendable {
        /// Hypothetical, disputed, or a proposal of anything but `proposed`.
        case tentative
        case negated
        /// No stated date: it cannot be placed (the timeline's unknown-date section).
        case undated
    }

    public struct SetAside: Codable, Equatable, Sendable {
        public let reason: SetAsideReason
        public let claimID: UUID
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public let status: KnowledgeStatus
        public let certainty: KnowledgeTemporalCertainty
        public let transitionIndex: Int
    }

    public let entityID: UUID
    public let lifecycle: KnowledgeLifecycle
    public let knownAt: Date
    public let transitions: [Transition]
    public let anomalies: [Anomaly]
    public let setAside: [SetAside]

    /// The status in force at valid time `moment`, or nil before the first
    /// transition could have started. `definite` only when the transition has
    /// definitely started, the next has definitely not, and neither order is
    /// ambiguous or unresolved; a transition ordered by the lifecycle is bounded by its
    /// neighbours (a completion stated for November that precedes a reopening
    /// on the 12th started by the 12th).
    public func state(at moment: Date) -> Snapshot? {
        let bounds = transitions.map { $0.stated.bounds }
        guard !bounds.contains(where: { $0 == nil }) else { return nil }
        let lowers = bounds.map { $0?.lower ?? .distantPast }, uppers = bounds.map { $0?.upper ?? .distantFuture }
        var effectiveLower = lowers, effectiveUpper = uppers
        for index in transitions.indices.dropFirst() {
            effectiveLower[index] = max(lowers[index], effectiveLower[index - 1])
        }
        for index in transitions.indices.reversed().dropFirst() {
            effectiveUpper[index] = max(effectiveLower[index], min(uppers[index], effectiveUpper[index + 1]))
        }
        guard let index = transitions.indices.last(where: { effectiveLower[$0] <= moment }) else { return nil }
        let nextMayHaveStarted = index + 1 < transitions.count && effectiveLower[index + 1] <= moment
        let settled: (Int) -> Bool = { [.statedTime, .lifecycle].contains(transitions[$0].orderBasis) }
        let definite = moment >= effectiveUpper[index] && !nextMayHaveStarted && settled(index)
            && (index + 1 >= transitions.count || settled(index + 1))
        return Snapshot(status: transitions[index].status, certainty: definite ? .definite : .possible,
                        transitionIndex: index)
    }
}

extension KnowledgeLifecycle {
    /// The lifecycle of `entityID` from the claims known at `knownAt`: its own
    /// `hasStatus` claims and, for a decision, a `supersedes` claim naming it as
    /// the replaced entity. Pure and deterministic; input order is irrelevant.
    public func project(entityID: UUID, knownAt: Date, claims: [KnowledgeTemporalClaim]) -> KnowledgeLifecycleProjection {
        var steps: [Step] = [], anomalies: [KnowledgeLifecycleProjection.Anomaly] = []
        var setAside: [KnowledgeLifecycleProjection.SetAside] = []
        for claim in claims where claim.recordedAt <= knownAt && (claim.retractedAt.map { knownAt < $0 } ?? true) {
            guard let raw = statusText(of: claim, entityID: entityID) else { continue }
            guard let status = KnowledgeStatus(rawValue: raw), statuses.contains(status) else {
                anomalies.append(.init(code: .outOfVocabulary, claimIDs: [claim.id])); continue
            }
            if claim.polarity == .negative { setAside.append(.init(reason: .negated, claimID: claim.id)); continue }
            // A proposal does establish that something was proposed.
            let proposalOfProposed = claim.modality == .proposed && status == .proposed
            if KnowledgeTemporalReducer.tentative.contains(claim.modality), !proposalOfProposed {
                setAside.append(.init(reason: .tentative, claimID: claim.id)); continue
            }
            guard let stated = claim.validFrom, let bounds = stated.bounds else {
                setAside.append(.init(reason: .undated, claimID: claim.id)); continue
            }
            steps.append(Step(status: status, stated: stated, lower: bounds.lower, upper: bounds.upper, claimIDs: [claim.id]))
        }
        let ordered = order(merge(steps))
        anomalies += ordered.anomalies
        // A status restated later is a confirmation, not a new change: it joins
        // the transition it repeats, which keeps its earliest stated date.
        var kept: [(step: Step, basis: KnowledgeLifecycleProjection.OrderBasis)] = []
        for (step, basis) in zip(ordered.steps, ordered.bases) {
            if let last = kept.last, last.step.status == step.status {
                kept[kept.count - 1].step.claimIDs += step.claimIDs
            } else {
                kept.append((step, basis))
            }
        }
        var transitions: [KnowledgeLifecycleProjection.Transition] = []
        for (index, entry) in kept.enumerated() {
            let previous = index > 0 ? kept[index - 1].step : nil
            if !allows(from: previous?.status, to: entry.step.status) {
                anomalies.append(.init(code: .invalidTransition,
                                       claimIDs: Self.sorted((previous?.claimIDs ?? []) + entry.step.claimIDs)))
            }
            transitions.append(.init(status: entry.step.status, from: previous?.status, stated: entry.step.stated,
                                     orderBasis: entry.basis, claimIDs: Self.sorted(entry.step.claimIDs)))
        }
        return KnowledgeLifecycleProjection(
            entityID: entityID, lifecycle: self, knownAt: knownAt, transitions: transitions,
            anomalies: anomalies.sorted { Self.key($0).lexicographicallyPrecedes(Self.key($1)) },
            setAside: setAside.sorted { ($0.reason.rawValue, $0.claimID.uuidString) < ($1.reason.rawValue, $1.claimID.uuidString) })
    }

    private struct Step {
        let status: KnowledgeStatus
        let stated: KnowledgeTemporalValue
        let lower: Date
        let upper: Date
        var claimIDs: [UUID]

        func overlaps(_ other: Step) -> Bool { lower < other.upper && other.lower < upper }
    }

    /// The status a claim states for the entity, as written; nil when the
    /// claim is not about its status.
    private func statusText(of claim: KnowledgeTemporalClaim, entityID: UUID) -> String? {
        if claim.subjectID == entityID, claim.predicate == .hasStatus, case let .enumeration(raw) = claim.value {
            return raw
        }
        if self == .decision, claim.predicate == .supersedes, claim.objectID == entityID {
            return KnowledgeStatus.superseded.rawValue
        }
        return nil
    }

    /// The same status stated for the same period by several claims is one
    /// statement. Statements of a status that only overlap stay apart: a
    /// reopening may separate two completions in one month, and the order
    /// search decides which are restatements.
    private func merge(_ steps: [Step]) -> [Step] {
        var merged: [String: Step] = [:]
        for step in steps {
            let key = step.status.rawValue + "|" + step.stated.precision.rawValue + "|" + step.stated.text
            if merged[key] == nil { merged[key] = step } else { merged[key]?.claimIDs += step.claimIDs }
        }
        return merged.values.sorted(by: Self.chronologically)
    }

    private static func chronologically(_ lhs: Step, _ rhs: Step) -> Bool {
        (lhs.lower, lhs.upper, lhs.status.rawValue, sorted(lhs.claimIDs).first?.uuidString ?? "")
            < (rhs.lower, rhs.upper, rhs.status.rawValue, sorted(rhs.claimIDs).first?.uuidString ?? "")
    }

    /// Larger groups of mutually overlapping changes are not searched.
    static let maximumSearchedGroup = 6

    /// Orders chronologically sorted steps. A group of steps whose stated
    /// periods overlap (directly or through each other) is ordered by the
    /// machine: every order that keeps disjoint periods in date order and is a
    /// valid path from the status before the group is considered. One such
    /// order is `lifecycle`; several are `ambiguous` (the first is kept); none
    /// is `unresolved` and keeps date order. A statement of the status already
    /// in force is a restatement, not a transition, and orders differing only
    /// in where a restatement falls count as one.
    private func order(_ steps: [Step]) -> (steps: [Step], bases: [KnowledgeLifecycleProjection.OrderBasis],
                                            anomalies: [KnowledgeLifecycleProjection.Anomaly]) {
        var result: [Step] = [], bases: [KnowledgeLifecycleProjection.OrderBasis] = []
        var anomalies: [KnowledgeLifecycleProjection.Anomaly] = []
        var start = 0
        while start < steps.count {
            var end = start + 1, reach = steps[start].upper
            while end < steps.count, steps[end].lower < reach {
                reach = max(reach, steps[end].upper)
                end += 1
            }
            let group = Array(steps[start..<end])
            start = end
            guard group.count > 1 else {
                result += group
                bases.append(.statedTime)
                continue
            }
            let ids = Self.sorted(group.flatMap(\.claimIDs))
            let search = group.count <= Self.maximumSearchedGroup ? paths(through: group, after: result.last?.status) : nil
            let basis: KnowledgeLifecycleProjection.OrderBasis
            switch search?.count {
            case 1?: basis = .lifecycle
            case 0?: basis = .unresolved
            default: basis = .ambiguous
            }
            if basis == .ambiguous { anomalies.append(.init(code: .ambiguousOrder, claimIDs: ids)) }
            if basis == .unresolved { anomalies.append(.init(code: .unresolvedOrder, claimIDs: ids)) }
            result += search?.first.map { $0.map { group[$0] } } ?? group
            bases += Array(repeating: basis, count: group.count)
        }
        return (result, bases, anomalies)
    }

    /// How many distinct status sequences through `group` follow `previous`
    /// (counting stops at two), and the first valid order in date-order
    /// preference.
    private func paths(through group: [Step], after previous: KnowledgeStatus?) -> (count: Int, first: [Int]?) {
        var sequences: Set<[KnowledgeStatus]> = [], first: [Int]?
        var placed: [Int] = [], used = Array(repeating: false, count: group.count)
        func extend(from last: KnowledgeStatus?) {
            guard sequences.count < 2 else { return }
            guard placed.count < group.count else {
                var sequence: [KnowledgeStatus] = []
                for status in placed.map({ group[$0].status }) where status != (sequence.last ?? previous) {
                    sequence.append(status)
                }
                sequences.insert(sequence)
                if first == nil { first = placed }
                return
            }
            for candidate in group.indices where !used[candidate] {
                // A step whose period ends before the candidate's begins must come first.
                let mustWait = group.indices.contains { other in
                    !used[other] && other != candidate && group[other].upper <= group[candidate].lower
                }
                let status = group[candidate].status
                guard !mustWait, status == last || allows(from: last, to: status) else { continue }
                used[candidate] = true
                placed.append(candidate)
                extend(from: group[candidate].status)
                placed.removeLast()
                used[candidate] = false
            }
        }
        extend(from: previous)
        return (sequences.count, first)
    }

    private static func key(_ anomaly: KnowledgeLifecycleProjection.Anomaly) -> [String] {
        [anomaly.code.rawValue] + anomaly.claimIDs.map(\.uuidString)
    }

    private static func sorted(_ ids: [UUID]) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
}

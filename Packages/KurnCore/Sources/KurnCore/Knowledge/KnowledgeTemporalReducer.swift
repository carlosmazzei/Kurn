//
//  KnowledgeTemporalReducer.swift
//  KurnCore
//
//  K3.1: what was true of an entity at a moment, as known at another moment
//  (ADR-003, CLAUDE.md "Knowledge Engine decisions"). Two clocks, never mixed:
//
//  - valid time is what the claims STATE (`validFrom`/`validTo`, half-open, at
//    their stated precision). "In October" covers the whole month, so a query
//    inside it gets `possible`, not a guess at the 1st.
//  - transaction time is when the store KNEW a claim (`recordedAt` up to
//    `retractedAt`, half-open). A meeting imported weeks late changes what is
//    known from its import onwards, never what was known before.
//
//  Single-valued predicates (a status, a due date) are reduced in valid-time
//  order only: a later stated start displaces an earlier one. Meeting order,
//  import order and input order never decide anything ("no last meeting wins").
//  When valid time cannot order two different values, both are returned and the
//  disagreement is surfaced as a conflict instead of being resolved.
//

import Foundation

public enum KnowledgeTemporalCertainty: String, Codable, Sendable, CaseIterable {
    /// The claim's stated interval contains the moment whatever the precise
    /// dates inside its stated precision are.
    case definite
    /// It may or may not: a bound's precision straddles the moment, the start
    /// was never stated, or a later value may already have displaced it.
    case possible
}

/// One canonical assertion as the reducer sees it. The host supplies only
/// claims that already passed source authorization and evidence checks.
public struct KnowledgeTemporalClaim: Codable, Equatable, Sendable {
    public let id: UUID
    public let subjectID: UUID
    public let predicate: KnowledgePredicate
    public let objectID: UUID?
    public let value: KnowledgeTypedValue?
    public let polarity: KnowledgePolarity
    public let modality: KnowledgeModality
    public let validFrom: KnowledgeTemporalValue?
    public let validTo: KnowledgeTemporalValue?
    /// Transaction time: when the store learned the claim, and when (if ever)
    /// it stopped holding it.
    public let recordedAt: Date
    public let retractedAt: Date?

    // swiftlint:disable:next function_parameter_count
    public init(id: UUID, subjectID: UUID, predicate: KnowledgePredicate, objectID: UUID? = nil,
                value: KnowledgeTypedValue? = nil, polarity: KnowledgePolarity = .positive,
                modality: KnowledgeModality, validFrom: KnowledgeTemporalValue?, validTo: KnowledgeTemporalValue? = nil,
                recordedAt: Date, retractedAt: Date? = nil) {
        self.id = id
        self.subjectID = subjectID
        self.predicate = predicate
        self.objectID = objectID
        self.value = value
        self.polarity = polarity
        self.modality = modality
        self.validFrom = validFrom
        self.validTo = validTo
        self.recordedAt = recordedAt
        self.retractedAt = retractedAt
    }
}

public struct KnowledgeTemporalState: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case outgoing, incoming }

    public struct Holding: Codable, Equatable, Sendable {
        public let predicate: KnowledgePredicate
        public let direction: Direction
        /// The other entity of a relation, from the queried entity's side.
        public let otherEntityID: UUID?
        public let value: KnowledgeTypedValue?
        public let polarity: KnowledgePolarity
        public let certainty: KnowledgeTemporalCertainty
        /// True when every supporting claim is tentative (proposed, hypothetical
        /// or disputed): shown, but it never established the state.
        public let isTentative: Bool
        /// The supporting claims' modalities, distinct and sorted by raw value.
        public let modalities: [KnowledgeModality]
        /// Every claim stating this same thing, sorted by ID.
        public let claimIDs: [UUID]
    }

    public enum ConflictReason: String, Codable, Sendable {
        /// Different values of a single-valued predicate both hold and their
        /// stated starts cannot be ordered.
        case unorderedValues = "unordered_values"
        /// A statement and its negation both hold and cannot be ordered.
        case contradictoryPolarity = "contradictory_polarity"
    }

    public struct Conflict: Codable, Equatable, Sendable {
        public let predicate: KnowledgePredicate
        public let reason: ConflictReason
        public let claimIDs: [UUID]
    }

    public let entityID: UUID
    public let validAt: Date
    public let knownAt: Date
    public let holdings: [Holding]
    public let conflicts: [Conflict]
}

public enum KnowledgeTemporalReducer {
    /// Predicates that have one value at a time per subject.
    public static let singleValued: Set<KnowledgePredicate> = [.hasStatus, .dueOn]

    /// Modalities that do not establish a state: a proposal, a hypothesis or a
    /// disputed claim is shown, never displaces an established statement and
    /// never conflicts with one. A later established statement still displaces
    /// it, so an approval ends a proposal.
    public static let tentative: Set<KnowledgeModality> = [.proposed, .hypothetical, .disputed]

    /// The state of `entityID` at valid time `validAt`, from the claims known
    /// at transaction time `knownAt`. Pure and deterministic: the result does
    /// not depend on the order of `claims`.
    public static func state(of entityID: UUID, validAt: Date, knownAt: Date,
                             claims: [KnowledgeTemporalClaim]) -> KnowledgeTemporalState {
        let known = claims.filter { $0.recordedAt <= knownAt && ($0.retractedAt.map { knownAt < $0 } ?? true) }
        var slots: [SlotKey: [Candidate]] = [:]
        for claim in known {
            let direction: KnowledgeTemporalState.Direction
            if claim.subjectID == entityID { direction = .outgoing }
            else if claim.objectID == entityID { direction = .incoming }
            else { continue }
            guard let held = holds(claim, at: validAt) else { continue }
            let other = direction == .outgoing ? claim.objectID : claim.subjectID
            let single = direction == .outgoing && singleValued.contains(claim.predicate)
            let key = SlotKey(predicate: claim.predicate, direction: direction,
                              detail: single ? "" : Self.detail(other: other, value: claim.value))
            slots[key, default: []].append(Candidate(claim: claim, certainty: held, other: other))
        }
        var holdings: [KnowledgeTemporalState.Holding] = []
        var conflicts: [KnowledgeTemporalState.Conflict] = []
        for (key, candidates) in slots {
            let reduced = reduce(candidates, at: validAt)
            conflicts += reduced.conflicts.map { .init(predicate: key.predicate, reason: $0.reason, claimIDs: $0.ids) }
            holdings += group(reduced.survivors, key: key)
        }
        holdings.sort { order($0).lexicographicallyPrecedes(order($1)) }
        conflicts.sort { order($0).lexicographicallyPrecedes(order($1)) }
        return KnowledgeTemporalState(entityID: entityID, validAt: validAt, knownAt: knownAt,
                                      holdings: holdings, conflicts: conflicts)
    }

    /// Whether a claim's own stated interval contains `moment`; nil when it
    /// definitely does not.
    static func holds(_ claim: KnowledgeTemporalClaim, at moment: Date) -> KnowledgeTemporalCertainty? {
        var certainty = KnowledgeTemporalCertainty.definite
        if let start = claim.validFrom?.bounds {
            if moment < start.lower { return nil }
            if moment < start.upper { certainty = .possible }
        } else {
            certainty = .possible
        }
        if let end = claim.validTo?.bounds {
            if moment >= end.upper { return nil }
            if moment >= end.lower { certainty = .possible }
        }
        return certainty
    }

    private struct SlotKey: Hashable {
        let predicate: KnowledgePredicate
        let direction: KnowledgeTemporalState.Direction
        let detail: String
    }

    private struct Candidate {
        let claim: KnowledgeTemporalClaim
        var certainty: KnowledgeTemporalCertainty
        let other: UUID?
        var isTentative: Bool { KnowledgeTemporalReducer.tentative.contains(claim.modality) }
        /// What the claim states, polarity and tentativeness included: two claims
        /// with the same statement support each other and never displace or
        /// conflict, and a tentative claim never merges into an established one.
        var statement: String {
            (isTentative ? "tentative|" : "established|") + claim.polarity.rawValue + "|"
                + KnowledgeTemporalReducer.detail(other: other, value: claim.value)
        }
    }

    private struct Disagreement {
        let reason: KnowledgeTemporalState.ConflictReason
        let ids: [UUID]
    }

    /// Within one slot, a candidate is displaced by a different established
    /// statement whose stated start is definitely later than its own: definitely
    /// once that later start has definitely passed, possibly while it may have.
    /// Different established statements that valid time cannot order both stay
    /// and disagree, each pair under its own reason.
    private static func reduce(_ candidates: [Candidate], at moment: Date) -> (survivors: [Candidate], conflicts: [Disagreement]) {
        guard Set(candidates.map(\.statement)).count > 1 else { return (candidates, []) }
        var survivors: [Candidate] = []
        for candidate in candidates {
            var certainty: KnowledgeTemporalCertainty? = candidate.certainty
            for other in candidates where other.statement != candidate.statement && !other.isTentative {
                guard let mine = candidate.claim.validFrom?.bounds, let theirs = other.claim.validFrom?.bounds,
                      theirs.lower >= mine.upper else { continue }
                if other.certainty == .definite { certainty = nil; break }
                certainty = .possible
            }
            if let certainty { survivors.append(Candidate(claim: candidate.claim, certainty: certainty, other: candidate.other)) }
        }
        // Undated claims are shown as possible and never decide a disagreement.
        // Only pairs whose stated starts overlap disagree; a pair that valid time
        // orders was already reduced above (its earlier side is at most possible).
        // Tentative claims never disagree with anything.
        let dated = survivors.filter { $0.claim.validFrom != nil && !$0.isTentative }
        var involved: [KnowledgeTemporalState.ConflictReason: Set<UUID>] = [:]
        for (index, one) in dated.enumerated() {
            for another in dated[(index + 1)...] where another.statement != one.statement {
                guard let first = one.claim.validFrom?.bounds, let second = another.claim.validFrom?.bounds,
                      first.lower < second.upper, second.lower < first.upper else { continue }
                let sameDetail = detail(other: one.other, value: one.claim.value)
                    == detail(other: another.other, value: another.claim.value)
                involved[sameDetail ? .contradictoryPolarity : .unorderedValues, default: []]
                    .formUnion([one.claim.id, another.claim.id])
            }
        }
        let conflicts = involved.map { reason, ids in
            Disagreement(reason: reason, ids: ids.sorted { $0.uuidString < $1.uuidString })
        }
        return (survivors, conflicts)
    }

    private static func group(_ candidates: [Candidate], key: SlotKey) -> [KnowledgeTemporalState.Holding] {
        Dictionary(grouping: candidates, by: \.statement).values.map { same in
            let first = same[0]
            return KnowledgeTemporalState.Holding(
                predicate: key.predicate, direction: key.direction, otherEntityID: first.other,
                value: first.claim.value, polarity: first.claim.polarity,
                certainty: same.contains { $0.certainty == .definite } ? .definite : .possible,
                isTentative: first.isTentative,
                modalities: Set(same.map(\.claim.modality)).sorted { $0.rawValue < $1.rawValue },
                claimIDs: same.map(\.claim.id).sorted { $0.uuidString < $1.uuidString })
        }
    }

    private static func order(_ holding: KnowledgeTemporalState.Holding) -> [String] {
        [holding.predicate.rawValue, holding.direction.rawValue, detail(other: holding.otherEntityID, value: holding.value),
         holding.polarity.rawValue, holding.isTentative ? "tentative" : "established"] + holding.claimIDs.map(\.uuidString)
    }

    private static func order(_ conflict: KnowledgeTemporalState.Conflict) -> [String] {
        [conflict.predicate.rawValue, conflict.reason.rawValue] + conflict.claimIDs.map(\.uuidString)
    }

    static func detail(other: UUID?, value: KnowledgeTypedValue?) -> String {
        if let other { return "entity:" + other.uuidString.lowercased() }
        guard let value else { return "" }
        switch value {
        case let .string(text): return "string:" + text
        case let .number(number, unit): return "number:\(number):" + (unit ?? "")
        case let .boolean(flag): return "boolean:\(flag)"
        case let .date(date): return "date:" + date.precision.rawValue + ":" + date.text
        case let .enumeration(text): return "enum:" + text
        }
    }
}

extension KnowledgeTemporalValue {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") { calendar.timeZone = utc }
        return calendar
    }()

    /// The stated period as a half-open UTC interval: an instant covers its
    /// second, a day its 24 hours, a month all of it. Calendar dates carry no
    /// time zone of their own, so they are read in UTC like instants are.
    public var bounds: (lower: Date, upper: Date)? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day ?? 1
        components.second = secondOfDay ?? 0
        guard let lower = Self.calendar.date(from: components) else { return nil }
        let step: DateComponents
        switch precision {
        case .instant: step = DateComponents(second: 1)
        case .day: step = DateComponents(day: 1)
        case .month: step = DateComponents(month: 1)
        case .unknown: return nil
        }
        guard let upper = Self.calendar.date(byAdding: step, to: lower) else { return nil }
        return (lower, upper)
    }
}

//
//  KnowledgeStateComparison.swift
//  KurnCore
//
//  K3.4: what changed for an entity between two moments (CLAUDE.md "Knowledge
//  comparison (K3.4)"). Each side is a K3.1 reducer state at its own valid time
//  and transaction time, so "what held on the 1st vs the 30th, as known today"
//  and "what we knew on the 1st vs what we know now" are the same operation.
//  Nothing is resolved: a conflict stays a conflict on its side, a precision
//  that straddles a moment stays `possible`, and no change is inferred from
//  the order of meetings.
//

import Foundation

public struct KnowledgeStateComparison: Equatable, Sendable {
    /// A moment on each clock.
    public struct Point: Equatable, Sendable {
        public let validAt: Date
        public let knownAt: Date

        public init(validAt: Date, knownAt: Date) {
            self.validAt = validAt
            self.knownAt = knownAt
        }

        /// The last second of `day` (UTC, like every stated date), known as of
        /// `knownAt`, or as of that same moment when `knownAt` is nil. Claims
        /// stated for that day are `possible` there: a day's precision cannot
        /// say whether it had already happened by its last second.
        public static func endOfDay(_ day: KnowledgeTemporalValue, knownAt: Date? = nil) -> Point? {
            guard day.precision == .day, let upper = day.bounds?.upper else { return nil }
            let moment = upper.addingTimeInterval(-1)
            return Point(validAt: moment, knownAt: knownAt ?? moment)
        }
    }

    public enum ChangeKind: String, Codable, Sendable, CaseIterable {
        /// The same slot holds a different statement (another status, a
        /// negation of what was stated).
        case changed
        /// Held only at the later point.
        case started
        /// Held only at the earlier point.
        case ended
        /// The same statement at both points; its certainty may differ.
        case unchanged
    }

    public struct Change: Equatable, Sendable {
        public let kind: ChangeKind
        public let predicate: KnowledgePredicate
        public let direction: KnowledgeTemporalState.Direction
        public let before: KnowledgeTemporalState.Holding?
        public let after: KnowledgeTemporalState.Holding?

        /// Unchanged, but definite at one point and only possible at the other.
        public var certaintyChanged: Bool {
            guard let before, let after else { return false }
            return before.certainty != after.certainty
        }
    }

    public let entityID: UUID
    public let earlier: KnowledgeTemporalState
    public let later: KnowledgeTemporalState
    /// Changed first, then started, ended and unchanged; within a kind by
    /// predicate, direction and statement. Identical for any input order.
    public let changes: [Change]

    public var hasDifferences: Bool { changes.contains { $0.kind != .unchanged || $0.certaintyChanged } }

    public static func compare(entityID: UUID, earlier: Point, later: Point,
                               claims: [KnowledgeTemporalClaim]) -> KnowledgeStateComparison {
        let before = KnowledgeTemporalReducer.state(of: entityID, validAt: earlier.validAt, knownAt: earlier.knownAt, claims: claims)
        let after = KnowledgeTemporalReducer.state(of: entityID, validAt: later.validAt, knownAt: later.knownAt, claims: claims)
        var beforeByStatement: [String: KnowledgeTemporalState.Holding] = [:]
        for holding in before.holdings { beforeByStatement[statement(holding)] = holding }
        var afterByStatement: [String: KnowledgeTemporalState.Holding] = [:]
        for holding in after.holdings { afterByStatement[statement(holding)] = holding }

        var changes: [Change] = []
        var ended: [String: [KnowledgeTemporalState.Holding]] = [:]
        var started: [String: [KnowledgeTemporalState.Holding]] = [:]
        for (key, holding) in beforeByStatement {
            if let same = afterByStatement[key] {
                changes.append(Change(kind: .unchanged, predicate: holding.predicate, direction: holding.direction,
                                      before: holding, after: same))
            } else {
                ended[slot(holding), default: []].append(holding)
            }
        }
        for (key, holding) in afterByStatement where beforeByStatement[key] == nil {
            started[slot(holding), default: []].append(holding)
        }
        // A slot that held exactly one statement at each point, and a different
        // one, changed. Anything less clear-cut (a conflict on either side,
        // even one whose other value held throughout) is left as what started
        // and ended.
        let beforeSlots = Dictionary(grouping: before.holdings, by: slot).mapValues(\.count)
        let afterSlots = Dictionary(grouping: after.holdings, by: slot).mapValues(\.count)
        for slotKey in Set(ended.keys).union(started.keys) {
            let gone = ended[slotKey] ?? [], new = started[slotKey] ?? []
            if gone.count == 1, new.count == 1, beforeSlots[slotKey] == 1, afterSlots[slotKey] == 1 {
                changes.append(Change(kind: .changed, predicate: gone[0].predicate, direction: gone[0].direction,
                                      before: gone[0], after: new[0]))
                continue
            }
            changes += gone.map { Change(kind: .ended, predicate: $0.predicate, direction: $0.direction, before: $0, after: nil) }
            changes += new.map { Change(kind: .started, predicate: $0.predicate, direction: $0.direction, before: nil, after: $0) }
        }
        changes.sort { order($0).lexicographicallyPrecedes(order($1)) }
        return KnowledgeStateComparison(entityID: entityID, earlier: before, later: after, changes: changes)
    }

    /// The temporal claims of `pages`, one per assertion, each naming the
    /// identities its page shows: a claim about a merged identity is a claim
    /// about the identity it was merged into, so its page compares as one.
    public static func claims(from pages: [KnowledgeWikiPage]) -> [KnowledgeTemporalClaim] {
        var seen = Set<UUID>()
        var claims: [KnowledgeTemporalClaim] = []
        for item in pages.flatMap({ $0.sections.flatMap(\.entries) }) where seen.insert(item.fact.id).inserted {
            let fact = item.fact
            claims.append(KnowledgeTemporalClaim(
                id: fact.id, subjectID: item.subject.id, predicate: fact.predicate,
                objectID: fact.objectID.map { item.object?.id ?? $0 }, value: fact.value,
                polarity: fact.qualifiers.polarity, modality: fact.qualifiers.modality,
                validFrom: fact.qualifiers.validFrom, validTo: fact.qualifiers.validTo,
                recordedAt: fact.source.recordedAt, observedAt: fact.source.observedAt))
        }
        return claims.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func slot(_ holding: KnowledgeTemporalState.Holding) -> String {
        let single = holding.direction == .outgoing && KnowledgeTemporalReducer.singleValued.contains(holding.predicate)
        return [holding.predicate.rawValue, holding.direction.rawValue,
                single ? "" : KnowledgeTemporalReducer.detail(other: holding.otherEntityID, value: holding.value)]
            .joined(separator: "|")
    }

    private static func statement(_ holding: KnowledgeTemporalState.Holding) -> String {
        [slot(holding), KnowledgeTemporalReducer.detail(other: holding.otherEntityID, value: holding.value),
         holding.polarity.rawValue, holding.isTentative ? "tentative" : "established"].joined(separator: "|")
    }

    private static func order(_ change: Change) -> [String] {
        let rank = ChangeKind.allCases.firstIndex(of: change.kind).map(String.init) ?? "9"
        let holding = change.before ?? change.after
        return [rank, change.predicate.rawValue, change.direction.rawValue]
            + [change.before, change.after].map { $0.map(statement) ?? "" }
            + (holding?.claimIDs.map(\.uuidString) ?? [])
    }
}

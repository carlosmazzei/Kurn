//
//  KnowledgeGraphTimeline.swift
//  KurnCore
//
//  K4.3: the Graph Explorer's evolution and compare modes (CLAUDE.md "Knowledge
//  graph explorer (K4.3)"). Which of a neighbourhood's edges held at a point in
//  valid time, as known at a transaction time, and what changed between two
//  points. The K3.1 reducer decides; nothing here orders claims by recording
//  date or picks a winner. Pure and deterministic.
//

import Foundation

public enum KnowledgeGraphTimeline {
    /// How an edge changed between two points.
    public enum Change: String, Codable, Sendable, CaseIterable {
        /// Held at the later point and not at the earlier one.
        case started
        /// Held at the earlier point and not at the later one.
        case ended
        /// Held at both.
        case kept
    }

    public struct EdgeChange: Equatable, Sendable {
        public let factID: UUID
        public let change: Change
        /// How certainly it held at each point; nil when it did not hold.
        public let before: KnowledgeTemporalCertainty?
        public let after: KnowledgeTemporalCertainty?
    }

    /// How certainly each of `graph`'s edges held at `point`. An edge whose
    /// claim does not hold there (it had not started, it was displaced or
    /// ended, or it was not yet known) is absent from the result.
    public static func holdings(of graph: KnowledgeGraph, at point: KnowledgeStateComparison.Point,
                                claims: [KnowledgeTemporalClaim]) -> [UUID: KnowledgeTemporalCertainty] {
        let edgeIDs = Set(graph.edges.map(\.factID))
        guard !edgeIDs.isEmpty else { return [:] }
        // An edge is an outgoing holding of its source, so the sources are enough.
        let sources = Set(graph.edges.map(\.sourceID)).sorted { $0.uuidString < $1.uuidString }
        let byID = Dictionary(claims.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: KnowledgeTemporalCertainty] = [:]
        for source in sources {
            let state = KnowledgeTemporalReducer.state(of: source, validAt: point.validAt, knownAt: point.knownAt, claims: claims)
            for holding in state.holdings where holding.direction == .outgoing && holding.otherEntityID != nil {
                for claimID in holding.claimIDs where edgeIDs.contains(claimID) {
                    // A holding folds equivalent claims and is definite when any
                    // of them is; each edge is one claim, so it is definite only
                    // when its own stated interval is too.
                    let own = byID[claimID].flatMap { KnowledgeTemporalReducer.holds($0, at: point.validAt) } ?? .possible
                    let certainty: KnowledgeTemporalCertainty = holding.certainty == .definite && own == .definite ? .definite : .possible
                    result[claimID] = strongest(result[claimID], certainty)
                }
            }
        }
        return result
    }

    /// The edges that held at either point and how each changed, by claim ID.
    /// An edge that held at neither is left out.
    public static func compare(_ graph: KnowledgeGraph, from earlier: KnowledgeStateComparison.Point,
                               to later: KnowledgeStateComparison.Point,
                               claims: [KnowledgeTemporalClaim]) -> [UUID: EdgeChange] {
        let before = holdings(of: graph, at: earlier, claims: claims)
        let after = holdings(of: graph, at: later, claims: claims)
        var result: [UUID: EdgeChange] = [:]
        for id in Set(before.keys).union(after.keys) {
            let change: Change
            switch (before[id], after[id]) {
            case (.some, .some): change = .kept
            case (.none, .some): change = .started
            default: change = .ended
            }
            result[id] = EdgeChange(factID: id, change: change, before: before[id], after: after[id])
        }
        return result
    }

    private static func strongest(_ lhs: KnowledgeTemporalCertainty?, _ rhs: KnowledgeTemporalCertainty) -> KnowledgeTemporalCertainty {
        lhs == .definite || rhs == .definite ? .definite : .possible
    }
}

//
//  KnowledgeInference.swift
//  KurnCore
//
//  K7.4 (first slice): derived edges over the graph's stated claims (CLAUDE.md
//  "Knowledge derived edges (K7.4)"). Pure and deterministic. A derived edge is a
//  consequence of premises, never evidence: it lists the claims it follows from
//  and is recomputed from them, so a premise that is retracted or no longer
//  readable simply stops producing it. Nothing here is stored or written.
//

import Foundation

public enum KnowledgeInference {
    public enum Rule: String, Codable, Sendable, CaseIterable {
        /// `a blocks b` (or `b dependsOn a`) chained: `a` precedes `c` through `b`.
        case transitiveBlocks = "transitive_blocks"
        /// `a supersedes b` and `b supersedes c`: `a` supersedes `c`.
        case supersessionChain = "supersession_chain"

        var predicate: KnowledgePredicate {
            switch self {
            case .transitiveBlocks: .blocks
            case .supersessionChain: .supersedes
            }
        }
    }

    public struct DerivedEdge: Equatable, Sendable {
        public let rule: Rule
        public let sourceID: UUID
        public let targetID: UUID
        public var predicate: KnowledgePredicate { rule.predicate }
        /// The stated claims, in chain order, this edge follows from (at least two).
        public let premiseFactIDs: [UUID]
        /// Always `.inferred`: shown dotted, off by default.
        public var modality: KnowledgeModality { .inferred }
    }

    public static let maximumHops = 4
    /// Output bound: a dense graph yields a refusal to list, never a silent cut.
    public static let maximumEdges = 400

    public struct Result: Equatable, Sendable {
        public let edges: [DerivedEdge]
        /// The edge bound cut the list short.
        public let isTruncated: Bool
        /// Identities on a cycle of a rule's premises; nothing is derived through them.
        public let cyclic: [Rule: [UUID]]
    }

    /// Derives edges from `edges`' established, positive, stated claims. A pair some input claim
    /// already speaks to for the rule (stated, negated, tentative or itself inferred) gets none: any
    /// input claim about the pair suppresses a derived edge, but only established stated claims are
    /// ever premises.
    public static func derive(from edges: [KnowledgeGraph.Edge], hops: Int = maximumHops) -> Result {
        let limit = min(max(hops, 2), maximumHops)
        var derived: [DerivedEdge] = []
        var cyclic: [Rule: [UUID]] = [:]
        var truncated = false
        // Rules in the order the output is sorted, so stopping at the bound keeps the first edges of that order.
        for rule in Rule.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let suppressed = statedPairs(for: rule, in: edges)
            let found = chains(links(for: rule, in: edges), limit: limit, suppressed: suppressed,
                               room: maximumEdges - derived.count)
            cyclic[rule] = found.cyclic.sorted { $0.uuidString < $1.uuidString }
            for item in found.paths {
                derived.append(DerivedEdge(rule: rule, sourceID: item.from, targetID: item.to,
                                           premiseFactIDs: item.premises))
            }
            if found.isTruncated { truncated = true; break }
        }
        return Result(edges: derived, isTruncated: truncated, cyclic: cyclic.filter { !$0.value.isEmpty })
    }

    // MARK: - Steps

    private struct Pair: Hashable { let source: UUID; let target: UUID }
    private struct Step { let from: UUID; let to: UUID; let factID: UUID }
    private struct Path { let from: UUID; let to: UUID; let premises: [UUID] }

    /// Every pair some input claim already speaks to for the rule, whatever its polarity or modality: a
    /// negated or tentative claim is no premise, but it still keeps a derived edge from contradicting it.
    private static func statedPairs(for rule: Rule, in edges: [KnowledgeGraph.Edge]) -> Set<Pair> {
        var pairs = Set<Pair>()
        for edge in edges where edge.sourceID != edge.targetID {
            switch (rule, edge.predicate) {
            case (.transitiveBlocks, .blocks), (.supersessionChain, .supersedes):
                pairs.insert(Pair(source: edge.sourceID, target: edge.targetID))
            case (.transitiveBlocks, .dependsOn):
                pairs.insert(Pair(source: edge.targetID, target: edge.sourceID))
            default:
                break
            }
        }
        return pairs
    }

    /// One directed step per established, positive, stated claim of the rule.
    private static func links(for rule: Rule, in edges: [KnowledgeGraph.Edge]) -> [Step] {
        var steps: [Step] = []
        for edge in edges where edge.polarity == .positive && !edge.isTentative && edge.modality != .inferred
            && edge.sourceID != edge.targetID {
            switch (rule, edge.predicate) {
            case (.transitiveBlocks, .blocks), (.supersessionChain, .supersedes):
                steps.append(Step(from: edge.sourceID, to: edge.targetID, factID: edge.factID))
            case (.transitiveBlocks, .dependsOn):
                steps.append(Step(from: edge.targetID, to: edge.sourceID, factID: edge.factID))
            default:
                break
            }
        }
        return steps.sorted { lhs, rhs in
            [lhs.from.uuidString, lhs.factID.uuidString, lhs.to.uuidString]
                .lexicographicallyPrecedes([rhs.from.uuidString, rhs.factID.uuidString, rhs.to.uuidString])
        }
    }

    /// Shortest chain of two or more steps from every identity, ties broken by
    /// step order; identities on a cycle neither start nor pass a chain.
    private static func chains(_ steps: [Step], limit: Int, suppressed: Set<Pair>,
                               room: Int) -> (paths: [Path], cyclic: Set<UUID>, isTruncated: Bool) {
        var next: [UUID: [Step]] = [:]
        for step in steps { next[step.from, default: []].append(step) }
        let cyclic = cycleMembers(next)
        var paths: [Path] = []
        for start in next.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !cyclic.contains(start) {
            var best: [UUID: [Step]] = [:]
            var frontier: [(UUID, [Step])] = [(start, [])]
            for _ in 0..<limit {
                var following: [(UUID, [Step])] = []
                for (node, trail) in frontier {
                    for step in next[node] ?? [] where !cyclic.contains(step.to) && step.to != start
                        && best[step.to] == nil {
                        let extended = trail + [step]
                        best[step.to] = extended
                        following.append((step.to, extended))
                    }
                }
                frontier = following
            }
            for (target, trail) in best.sorted(by: { $0.key.uuidString < $1.key.uuidString })
            where trail.count >= 2 && !suppressed.contains(Pair(source: start, target: target)) {
                if paths.count >= room { return (paths, cyclic, true) }
                paths.append(Path(from: start, to: target, premises: trail.map(\.factID)))
            }
        }
        return (paths, cyclic, false)
    }

    /// Identities that can reach themselves.
    private static func cycleMembers(_ next: [UUID: [Step]]) -> Set<UUID> {
        var members = Set<UUID>()
        for start in next.keys {
            var seen = Set<UUID>()
            var stack = next[start]?.map(\.to) ?? []
            while let node = stack.popLast() {
                if node == start { members.insert(start); break }
                if seen.insert(node).inserted { stack.append(contentsOf: next[node]?.map(\.to) ?? []) }
            }
        }
        return members
    }
}

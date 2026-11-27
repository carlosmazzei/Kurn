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

    /// Derives edges from `edges`' established, positive, stated claims. A pair
    /// already joined by a stated claim of the same predicate gets none.
    public static func derive(from edges: [KnowledgeGraph.Edge], hops: Int = maximumHops) -> Result {
        let limit = min(max(hops, 2), maximumHops)
        var derived: [DerivedEdge] = []
        var cyclic: [Rule: [UUID]] = [:]
        for rule in Rule.allCases {
            let steps = links(for: rule, in: edges)
            let stated = Set(steps.map { Pair(source: $0.from, target: $0.to) })
            let found = chains(steps, limit: limit)
            cyclic[rule] = found.cyclic.sorted { $0.uuidString < $1.uuidString }
            for item in found.paths where !stated.contains(Pair(source: item.from, target: item.to)) {
                derived.append(DerivedEdge(rule: rule, sourceID: item.from, targetID: item.to,
                                           premiseFactIDs: item.premises))
            }
        }
        derived.sort { lhs, rhs in
            let left = [lhs.rule.rawValue, lhs.sourceID.uuidString, lhs.targetID.uuidString]
            let right = [rhs.rule.rawValue, rhs.sourceID.uuidString, rhs.targetID.uuidString]
            return left.lexicographicallyPrecedes(right)
        }
        let truncated = derived.count > maximumEdges
        return Result(edges: Array(derived.prefix(maximumEdges)), isTruncated: truncated,
                      cyclic: cyclic.filter { !$0.value.isEmpty })
    }

    // MARK: - Steps

    private struct Pair: Hashable { let source: UUID; let target: UUID }
    private struct Step { let from: UUID; let to: UUID; let factID: UUID }
    private struct Path { let from: UUID; let to: UUID; let premises: [UUID] }

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
            [lhs.from.uuidString, lhs.to.uuidString, lhs.factID.uuidString]
                .lexicographicallyPrecedes([rhs.from.uuidString, rhs.to.uuidString, rhs.factID.uuidString])
        }
    }

    /// Shortest chain of two or more steps from every identity, ties broken by
    /// step order; identities on a cycle neither start nor pass a chain.
    private static func chains(_ steps: [Step], limit: Int) -> (paths: [Path], cyclic: Set<UUID>) {
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
            for (target, trail) in best.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where trail.count >= 2 {
                paths.append(Path(from: start, to: target, premises: trail.map(\.factID)))
            }
        }
        return (paths, cyclic)
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

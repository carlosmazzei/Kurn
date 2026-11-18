//
//  KnowledgeGraph.swift
//  KurnCore
//
//  K4.1: a bounded neighbourhood of the relationship graph (CLAUDE.md "Knowledge
//  graph query (K4.1)"). A projection of the same authorized, evidence-checked
//  pages the reader shows, never a second store: a node is an identity a page
//  shows (a merged identity is the one it was merged into) and an edge is one
//  claim between two of them, in its stated direction. A query walks out from
//  one entity breadth first within explicit depth, node and edge bounds, says
//  when a bound cut it short and which shown nodes have more to explore, and
//  reports `supersedes` cycles instead of ordering through them.
//

import Foundation

public struct KnowledgeGraph: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let entity: KnowledgeWikiSnapshot.Entity
        /// Hops from the query's root.
        public let depth: Int

        public var id: UUID { entity.id }
    }

    public struct Edge: Equatable, Sendable {
        /// The claim the edge shows; an edge is one claim.
        public let factID: UUID
        public let sourceID: UUID
        public let targetID: UUID
        public let predicate: KnowledgePredicate
        public let polarity: KnowledgePolarity
        public let modality: KnowledgeModality
        /// The first cited passage, for an ID-only evidence route.
        public let evidenceID: UUID?

        /// A proposal, hypothesis or disputed claim.
        public var isTentative: Bool { KnowledgeTemporalReducer.tentative.contains(modality) }
    }

    public struct Query: Hashable, Sendable {
        /// The largest bounds a query may ask for.
        public static let maximumDepth = 2
        public static let maximumNodes = 40
        public static let maximumEdges = 80

        public let rootID: UUID
        public let depth: Int
        public let maxNodes: Int
        public let maxEdges: Int
        /// Predicates to follow; empty follows every predicate.
        public let predicates: Set<KnowledgePredicate>
        public let includesTentative: Bool
        public let includesNegated: Bool

        /// Bounds outside their range are clamped to it: depth 0…2, 1…40
        /// nodes, 0…80 edges.
        public init(rootID: UUID, depth: Int = 1, maxNodes: Int = maximumNodes, maxEdges: Int = maximumEdges,
                    predicates: Set<KnowledgePredicate> = [], includesTentative: Bool = true, includesNegated: Bool = true) {
            self.rootID = rootID
            self.depth = min(max(depth, 0), Self.maximumDepth)
            self.maxNodes = min(max(maxNodes, 1), Self.maximumNodes)
            self.maxEdges = min(max(maxEdges, 0), Self.maximumEdges)
            self.predicates = predicates
            self.includesTentative = includesTentative
            self.includesNegated = includesNegated
        }

        func follows(_ edge: Edge) -> Bool {
            (predicates.isEmpty || predicates.contains(edge.predicate)) && (includesTentative || !edge.isTentative)
                && (includesNegated || edge.polarity == .positive)
        }
    }

    public let query: Query
    /// The root first, then by depth, then by name and ID.
    public let nodes: [Node]
    /// Nearest first (the deeper end's depth), then by predicate, ends and claim.
    public let edges: [Edge]
    /// A node or edge bound cut the walk short; the depth bound alone does not.
    public let isTruncated: Bool
    /// Shown nodes with a followed claim the graph does not show: the places
    /// to expand from next, in node order.
    public let frontier: [UUID]
    /// Each set of identities whose `supersedes` claims (established, not
    /// negated) form a cycle and that touches a shown node, IDs sorted; a
    /// cycle is reported, never ordered.
    public let supersessionCycles: [[UUID]]
}

/// The relationship graph of a set of pages, indexed once and queried many
/// times. Pure and deterministic: the same pages give the same answers in any
/// order.
public struct KnowledgeGraphIndex: Sendable {
    private let entities: [UUID: KnowledgeWikiSnapshot.Entity]
    /// Each identity's incident edges, in the order a walk visits them.
    private let adjacency: [UUID: [KnowledgeGraph.Edge]]
    private let cycles: [[UUID]]

    public init(pages: [KnowledgeWikiPage]) {
        var entities: [UUID: KnowledgeWikiSnapshot.Entity] = [:]
        var edges: [UUID: KnowledgeGraph.Edge] = [:]
        for page in pages { entities[page.entity.id] = entities[page.entity.id] ?? page.entity }
        for item in pages.flatMap({ $0.sections.flatMap(\.entries) }) where edges[item.fact.id] == nil {
            guard let object = item.object else { continue }
            entities[item.subject.id] = entities[item.subject.id] ?? item.subject
            entities[object.id] = entities[object.id] ?? object
            edges[item.fact.id] = KnowledgeGraph.Edge(
                factID: item.fact.id, sourceID: item.subject.id, targetID: object.id, predicate: item.fact.predicate,
                polarity: item.fact.qualifiers.polarity, modality: item.fact.qualifiers.modality,
                evidenceID: item.fact.source.evidence.first?.id)
        }
        var adjacency: [UUID: [KnowledgeGraph.Edge]] = [:]
        // A claim whose two ends are one identity (after a merge) is not drawn.
        for edge in edges.values where edge.sourceID != edge.targetID {
            adjacency[edge.sourceID, default: []].append(edge)
            adjacency[edge.targetID, default: []].append(edge)
        }
        self.entities = entities
        self.adjacency = adjacency.mapValues { list in
            list.sorted { Self.visitKey($0).lexicographicallyPrecedes(Self.visitKey($1)) }
        }
        cycles = Self.supersessionCycles(Array(edges.values))
    }

    /// The neighbourhood `query` asks for, or nil when its root is not an
    /// identity these pages show.
    public func query(_ query: KnowledgeGraph.Query) -> KnowledgeGraph? {
        guard let root = entities[query.rootID] else { return nil }
        var depths: [UUID: Int] = [root.id: 0]
        var order: [UUID] = [root.id]
        var truncated = false
        var queue = [root.id], cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            guard let depth = depths[current], depth < query.depth else { continue }
            for edge in adjacency[current] ?? [] where query.follows(edge) {
                let other = edge.sourceID == current ? edge.targetID : edge.sourceID
                guard depths[other] == nil else { continue }
                guard order.count < query.maxNodes else {
                    truncated = true
                    break
                }
                depths[other] = depth + 1
                order.append(other)
                queue.append(other)
            }
        }
        var candidates: [KnowledgeGraph.Edge] = []
        var seen = Set<UUID>()
        for id in order {
            for edge in adjacency[id] ?? [] where query.follows(edge) && seen.insert(edge.factID).inserted {
                if depths[edge.sourceID] != nil, depths[edge.targetID] != nil { candidates.append(edge) }
            }
        }
        candidates.sort { Self.shownKey($0, depths).lexicographicallyPrecedes(Self.shownKey($1, depths)) }
        if candidates.count > query.maxEdges { truncated = true }
        let shown = Array(candidates.prefix(query.maxEdges))
        let shownIDs = Set(shown.map(\.factID))
        let nodes = order.compactMap { id in entities[id].map { KnowledgeGraph.Node(entity: $0, depth: depths[id] ?? 0) } }
            .sorted { Self.nodeKey($0).lexicographicallyPrecedes(Self.nodeKey($1)) }
        let frontier = nodes.map(\.id).filter { id in
            (adjacency[id] ?? []).contains { query.follows($0) && !shownIDs.contains($0.factID) }
        }
        let touched = Set(order)
        return KnowledgeGraph(query: query, nodes: nodes, edges: shown, isTruncated: truncated, frontier: frontier,
                              supersessionCycles: cycles.filter { cycle in cycle.contains { touched.contains($0) } })
    }

    // MARK: - Ordering

    private static func visitKey(_ edge: KnowledgeGraph.Edge) -> [String] {
        [edge.predicate.rawValue, edge.sourceID.uuidString, edge.targetID.uuidString, edge.factID.uuidString]
    }

    private static func shownKey(_ edge: KnowledgeGraph.Edge, _ depths: [UUID: Int]) -> [String] {
        let depth = max(depths[edge.sourceID] ?? 0, depths[edge.targetID] ?? 0)
        return [String(depth)] + visitKey(edge)
    }

    private static func nodeKey(_ node: KnowledgeGraph.Node) -> [String] {
        [String(node.depth), KnowledgeEntityResolver.normalizedName(node.entity.name), node.id.uuidString]
    }

    // MARK: - Supersession cycles

    /// The strongly connected components of the established, positive
    /// `supersedes` claims that are cycles: two or more identities, or one
    /// that supersedes itself. Sorted by their first ID.
    static func supersessionCycles(_ edges: [KnowledgeGraph.Edge]) -> [[UUID]] {
        let relevant = edges.filter { $0.predicate == .supersedes && $0.polarity == .positive && !$0.isTentative }
        var next: [UUID: [UUID]] = [:]
        var selfLoops = Set<UUID>()
        for edge in relevant {
            next[edge.sourceID, default: []].append(edge.targetID)
            if next[edge.targetID] == nil { next[edge.targetID] = [] }
            if edge.sourceID == edge.targetID { selfLoops.insert(edge.sourceID) }
        }
        let components = stronglyConnected(next.mapValues { $0.sorted { $0.uuidString < $1.uuidString } })
        return components.filter { $0.count > 1 || $0.first.map(selfLoops.contains) == true }
            .map { $0.sorted { $0.uuidString < $1.uuidString } }
            .sorted { ($0.first?.uuidString ?? "") < ($1.first?.uuidString ?? "") }
    }

    /// Tarjan's algorithm, iterative so a long chain cannot exhaust the stack.
    private static func stronglyConnected(_ graph: [UUID: [UUID]]) -> [[UUID]] {
        var index: [UUID: Int] = [:], low: [UUID: Int] = [:]
        var onStack = Set<UUID>(), stack: [UUID] = [], components: [[UUID]] = []
        var counter = 0
        for start in graph.keys.sorted(by: { $0.uuidString < $1.uuidString }) where index[start] == nil {
            var work: [(node: UUID, next: Int)] = [(start, 0)]
            index[start] = counter; low[start] = counter; counter += 1
            stack.append(start); onStack.insert(start)
            while let top = work.last {
                let node = top.node, position = top.next
                let successors = graph[node] ?? []
                if position < successors.count {
                    work[work.count - 1].next += 1
                    let successor = successors[position]
                    if index[successor] == nil {
                        index[successor] = counter; low[successor] = counter; counter += 1
                        stack.append(successor); onStack.insert(successor)
                        work.append((successor, 0))
                    } else if onStack.contains(successor) {
                        low[node] = min(low[node] ?? 0, index[successor] ?? 0)
                    }
                    continue
                }
                work.removeLast()
                if let parent = work.last?.node { low[parent] = min(low[parent] ?? 0, low[node] ?? 0) }
                guard low[node] == index[node] else { continue }
                var component: [UUID] = []
                while let member = stack.popLast() {
                    onStack.remove(member)
                    component.append(member)
                    if member == node { break }
                }
                components.append(component)
            }
        }
        return components
    }
}

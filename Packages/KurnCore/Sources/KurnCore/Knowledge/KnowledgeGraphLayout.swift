//
//  KnowledgeGraphLayout.swift
//  KurnCore
//
//  K4.2: positions for a graph neighbourhood (CLAUDE.md "Knowledge graph layout
//  (K4.2)"). A force-directed layout (Fruchterman-Reingold) in the unit square,
//  deterministic by node ID and seed: nodes are visited in ID order, start from
//  rings by depth at angles drawn from a hash of the seed and the ID, and move
//  for a fixed number of steps with a cooling budget. Positions already shown
//  can be held fixed, so a graph that grows keeps the nodes the reader has seen
//  where they were and only places the new ones.
//

import Foundation

public struct KnowledgeGraphLayout: Equatable, Sendable {
    public struct Point: Equatable, Hashable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Steps a layout runs unless asked otherwise.
    public static let defaultIterations = 150
    /// Every position stays this far from the square's edges.
    public static let margin = 0.06

    public let seed: UInt64
    /// One position per node of the graph, inside [margin, 1 - margin].
    public let positions: [UUID: Point]

    /// Lays out `graph`. Nodes in `fixed` keep exactly that position; the root
    /// sits at the centre unless it is fixed elsewhere; every other node is
    /// placed by the forces. The same graph, seed and fixed positions always
    /// give the same layout, whatever the order of the graph's nodes and edges.
    public static func layout(_ graph: KnowledgeGraph, seed: UInt64 = 0, fixed: [UUID: Point] = [:],
                              iterations: Int = defaultIterations) -> KnowledgeGraphLayout {
        let ids = graph.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return KnowledgeGraphLayout(seed: seed, positions: [:]) }
        let depth = Dictionary(graph.nodes.map { ($0.id, $0.depth) }, uniquingKeysWith: { first, _ in first })
        var pinned = Set<Int>()
        var points = ids.enumerated().map { offset, id -> Point in
            if let point = fixed[id], point.x.isFinite, point.y.isFinite {
                pinned.insert(offset)
                return clamped(point)
            }
            if id == graph.query.rootID {
                pinned.insert(offset)
                return Point(x: 0.5, y: 0.5)
            }
            let angle = 2 * Double.pi * unit(hash(seed, id))
            let radius = 0.18 * Double(max(depth[id] ?? 1, 1))
            return clamped(Point(x: 0.5 + radius * cos(angle), y: 0.5 + radius * sin(angle)))
        }
        let springs = springs(graph.edges, ids: ids)
        let ideal = min(0.3, 0.8 * (1 / Double(ids.count)).squareRoot())
        let steps = max(iterations, 0)
        for step in 0..<steps {
            let budget = 0.1 * Double(steps - step) / Double(steps)
            var moves = [Point](repeating: Point(x: 0, y: 0), count: ids.count)
            for first in ids.indices {
                for second in ids.indices where second > first {
                    let push = repulsion(points[first], points[second], ideal: ideal, pair: (ids[first], ids[second]), seed: seed)
                    moves[first] = add(moves[first], push)
                    moves[second] = add(moves[second], Point(x: -push.x, y: -push.y))
                }
            }
            for spring in springs {
                let pull = attraction(points[spring.first], points[spring.second], ideal: ideal, weight: spring.weight)
                moves[spring.first] = add(moves[spring.first], Point(x: -pull.x, y: -pull.y))
                moves[spring.second] = add(moves[spring.second], pull)
            }
            for index in ids.indices where !pinned.contains(index) {
                let length = (moves[index].x * moves[index].x + moves[index].y * moves[index].y).squareRoot()
                guard length > 0 else { continue }
                let scale = min(length, budget) / length
                points[index] = clamped(Point(x: points[index].x + moves[index].x * scale,
                                              y: points[index].y + moves[index].y * scale))
            }
        }
        return KnowledgeGraphLayout(seed: seed, positions: Dictionary(uniqueKeysWithValues: zip(ids, points)))
    }

    // MARK: - Forces

    private struct Spring {
        let first: Int
        let second: Int
        let weight: Double
    }

    /// One spring per pair of shown nodes, weighted by the claims between them.
    private static func springs(_ edges: [KnowledgeGraph.Edge], ids: [UUID]) -> [Spring] {
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var weights: [Int: [Int: Double]] = [:]
        for edge in edges {
            guard let source = index[edge.sourceID], let target = index[edge.targetID], source != target else { continue }
            let low = min(source, target), high = max(source, target)
            weights[low, default: [:]][high, default: 0] += 1
        }
        return weights.keys.sorted().flatMap { low in
            (weights[low] ?? [:]).keys.sorted().map { high in Spring(first: low, second: high, weight: weights[low]?[high] ?? 1) }
        }
    }

    /// The push on the first node away from the second; coincident nodes are
    /// pushed apart in a direction drawn from their IDs and the seed.
    private static func repulsion(_ first: Point, _ second: Point, ideal: Double, pair: (UUID, UUID), seed: UInt64) -> Point {
        var delta = Point(x: first.x - second.x, y: first.y - second.y)
        var distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        if distance < 1e-9 {
            let angle = 2 * Double.pi * unit(hash(hash(seed, pair.0), pair.1))
            delta = Point(x: cos(angle) * 1e-6, y: sin(angle) * 1e-6)
            distance = 1e-6
        }
        let force = ideal * ideal / distance
        return Point(x: delta.x / distance * force, y: delta.y / distance * force)
    }

    /// The pull on the second node towards the first.
    private static func attraction(_ first: Point, _ second: Point, ideal: Double, weight: Double) -> Point {
        let delta = Point(x: first.x - second.x, y: first.y - second.y)
        let distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard distance > 1e-9 else { return Point(x: 0, y: 0) }
        let force = weight * distance * distance / ideal
        return Point(x: delta.x / distance * force, y: delta.y / distance * force)
    }

    private static func add(_ lhs: Point, _ rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }

    private static func clamped(_ point: Point) -> Point {
        Point(x: min(max(point.x, margin), 1 - margin), y: min(max(point.y, margin), 1 - margin))
    }

    // MARK: - Deterministic hashing

    /// SplitMix64 over the seed and the ID's sixteen bytes: stable across runs
    /// and processes, unlike `Hasher`.
    static func hash(_ seed: UInt64, _ id: UUID) -> UInt64 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var state = seed
        for chunk in stride(from: 0, to: 16, by: 8) {
            let word = bytes[chunk..<chunk + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            state = mix(state ^ word)
        }
        return state
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var mixed = value &+ 0x9E37_79B9_7F4A_7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// A value in [0, 1) from the top 53 bits of `value`.
    private static func unit(_ value: UInt64) -> Double { Double(value >> 11) / Double(UInt64(1) << 53) }
}

import CoreGraphics
import Foundation
import KurnCore

/// Words, positions and links for the Graph Explorer (K4.3, CLAUDE.md "Knowledge
/// graph explorer (K4.3)"). The neighbourhood and its positions come from
/// `KnowledgeGraphQueryService`; this turns them into what the canvas draws,
/// the hit-testing overlay and the list read by VoiceOver. Nothing here decides
/// what is shown: that is the query's bounds and filters.
enum KnowledgeGraphPresentation {
    /// What the reader chose to show; per view, never persisted.
    struct Options: Equatable {
        var depth = 1
        var includesTentative = true
        var includesNegated = true
        /// Claims a model inferred are off until the reader asks for them.
        var includesInferred = false

        func query(root: UUID) -> KnowledgeGraph.Query {
            KnowledgeGraph.Query(rootID: root, depth: depth, includesTentative: includesTentative, includesNegated: includesNegated,
                                 includesInferred: includesInferred)
        }
    }

    /// Where the reader is in one graph opened from an entity: the node it is
    /// centred on, the one selected, the filters and the chosen view. Kept by
    /// `KnowledgeGraphQueryService` so opening a page and coming back finds the
    /// graph as it was left; it holds IDs only, never content.
    struct Exploration: Equatable {
        var root: UUID
        var selected: UUID
        var options = Options()
        /// nil follows VoiceOver: the list while it runs, else the drawing.
        var showsList: Bool?
        var mode = GraphMode.relationships
        /// The days the evolution and compare modes read; nil until chosen.
        var day: Date?
        var from: Date?
        var to: Date?
        /// Read each day with only what had been recorded by its end.
        var asKnownThen = false

        init(root: UUID) {
            self.root = root
            selected = root
        }

        mutating func recentre(on id: UUID) {
            root = id
            selected = id
        }
    }

    struct Node: Equatable, Identifiable {
        let id: UUID
        let name: String
        let depth: Int
        let isRoot: Bool
        /// The graph does not show every claim this node has.
        let hasMore: Bool
        /// Position in the unit square, from the layout.
        let point: KnowledgeGraphLayout.Point
    }

    struct Edge: Equatable, Identifiable {
        var id: UUID { factID }
        let factID: UUID
        let sourceID: UUID
        let targetID: UUID
        /// The claim as a sentence, in its stated direction.
        let text: String
        let isTentative: Bool
        let isNegated: Bool
        let isInferred: Bool
        let evidence: KnowledgeBrowserRoute?
        /// What the evolution or compare mode says about it; nil otherwise.
        var state: EdgeState?
    }

    struct Scene: Equatable {
        let rootID: UUID
        /// Root first, then by depth and name.
        let nodes: [Node]
        /// Nearest first.
        let edges: [Edge]
        let isTruncated: Bool
        /// Each supersession cycle among the shown identities, as names.
        let cycles: [[String]]

        func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }

        /// The claims that touch `id`, nearest first.
        func edges(touching id: UUID) -> [Edge] { edges.filter { $0.sourceID == id || $0.targetID == id } }

        /// A one-sentence description of the drawing for VoiceOver.
        var summary: String { String(format: copy("summary"), nodes.count, edges.count) }
    }

    /// The scene for `graph`. `pages` name what the drawing does not show: a
    /// supersession loop is reported whole, including members beyond the bounds.
    /// With `states` (evolution or compare), only the edges it names are shown.
    static func scene(_ graph: KnowledgeGraph, layout: KnowledgeGraphLayout, pages: [KnowledgeWikiPage] = [],
                      states: [UUID: EdgeState]? = nil) -> Scene {
        let names = Dictionary(graph.nodes.map { ($0.id, $0.entity.name) } + pages.map { ($0.entity.id, $0.entity.name) },
                               uniquingKeysWith: { first, _ in first })
        let more = Set(graph.frontier)
        let nodes = graph.nodes.compactMap { node -> Node? in
            guard let point = layout.positions[node.id] else { return nil }
            return Node(id: node.id, name: node.entity.name, depth: node.depth, isRoot: node.id == graph.query.rootID,
                        hasMore: more.contains(node.id), point: point)
        }
        let edges = graph.edges.compactMap { edge -> Edge? in
            if let states, states[edge.factID] == nil { return nil }
            return Edge(factID: edge.factID, sourceID: edge.sourceID, targetID: edge.targetID,
                        text: text(edge, names: names), isTentative: edge.isTentative, isNegated: edge.polarity == .negative,
                        isInferred: edge.modality == .inferred,
                        evidence: edge.evidenceID.map { .evidence(assertionID: edge.factID, evidenceID: $0) },
                        state: states?[edge.factID])
        }
        let cycles = graph.supersessionCycles.map { cycle in cycle.map { names[$0] ?? copy("unnamed") } }
        return Scene(rootID: graph.query.rootID, nodes: nodes, edges: edges, isTruncated: graph.isTruncated, cycles: cycles)
    }

    /// The claim an edge shows, worded like the reader's claims.
    static func text(_ edge: KnowledgeGraph.Edge, names: [UUID: String]) -> String {
        let predicate = NSLocalizedString("knowledge.predicate." + edge.predicate.rawValue, comment: "Claim predicate")
        let claim = String(format: NSLocalizedString("detail.knowledge.claim", comment: "Subject, predicate and object in source direction"),
                           names[edge.sourceID] ?? copy("unnamed"), predicate, names[edge.targetID] ?? copy("unnamed"))
        guard edge.polarity == .negative else { return claim }
        return String(format: NSLocalizedString("detail.knowledge.negative_claim", comment: "Explicitly negated structured claim"), claim)
    }

    /// Notes shown beside an edge. The drawing dashes tentative claims and
    /// crosses out negated ones; in words, a negated claim's sentence already
    /// says so and a tentative one is noted here (never colour alone).
    static func notes(_ edge: Edge) -> [String] {
        [note(edge.state)].compactMap { $0 } + (edge.isTentative ? [KnowledgeTimelinePresentation.text("tentative")] : [])
            + (edge.isInferred ? [copy("inferred")] : [])
    }

    /// Where a unit-square point sits in a canvas of `size`.
    static func point(_ point: KnowledgeGraphLayout.Point, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    /// The accessibility label of a node's hit target.
    static func label(_ node: Node, scene: Scene) -> String {
        var parts = [node.name, String(format: copy("connections"), scene.edges(touching: node.id).count)]
        if node.isRoot { parts.append(copy("centre")) }
        if node.hasMore { parts.append(copy("has_more")) }
        return parts.joined(separator: ", ")
    }

    /// The nodes in reading order for the list alternative: root first, then
    /// nearest first, each with the claims that touch it.
    static func listSections(_ scene: Scene) -> [ListSection] {
        scene.nodes.map { ListSection(node: $0, edges: scene.edges(touching: $0.id)) }
    }

    struct ListSection: Equatable, Identifiable {
        var id: UUID { node.id }
        let node: Node
        let edges: [Edge]
    }

    static func copy(_ key: String) -> String { NSLocalizedString("knowledge.graph." + key, comment: "Knowledge graph explorer") }
}

import Foundation
import KurnCore

/// The Graph Explorer's context lanes mode (K4.3, CLAUDE.md "Knowledge graph
/// explorer (K4.3)"): the same neighbourhood, with one horizontal lane per
/// context the shown relationships were said in (an internal meeting, a vendor
/// discussion, a conference session). A relationship belongs to its meeting's
/// context; a node sits in the lane most of its shown relationships belong to,
/// keeping its horizontal place. Every relationship and node names its
/// context in words, so lanes are never told apart by position or colour alone.
extension KnowledgeGraphPresentation {
    struct Lane: Equatable, Identifiable {
        /// The context's ID, or "unknown".
        let id: String
        /// The context's name, else its kind.
        let title: String
        /// The kind, when the title is the context's own name.
        let detail: String?
    }

    /// The share of a lane's height its nodes are spread over, centred; the
    /// rest keeps them clear of the lane's edges and label.
    static let laneSpread = 0.7

    /// `scene` laid out in context lanes: lanes in kind order (unknown last),
    /// then by title; edges and nodes carry their lane's title; each node keeps
    /// its x and is placed within its lane in the order the layout gave it.
    static func laned(_ scene: Scene, pages: [KnowledgeWikiPage], contexts: [UUID: KnowledgeBrowserContext]) -> Scene {
        var meetings: [UUID: UUID] = [:]
        for page in pages {
            for entry in page.sections.flatMap(\.entries) { meetings[entry.fact.id] = entry.fact.source.meetingID }
        }
        let edgeContexts = Dictionary(uniqueKeysWithValues: scene.edges.map { edge in
            (edge.factID, meetings[edge.factID].flatMap { contexts[$0] } ?? .unknown)
        })
        let lanes = Dictionary(edgeContexts.values.map { (laneID($0), $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted(by: laneOrder).map(lane)
        guard !lanes.isEmpty else { return scene }
        let index = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
        let edgeLanes = edgeContexts.mapValues { index[laneID($0)] ?? 0 }
        let nodeLanes = Dictionary(uniqueKeysWithValues: scene.nodes.map { node in
            (node.id, homeLane(of: node.id, scene: scene, edgeLanes: edgeLanes))
        })
        let count = Double(lanes.count)
        let nodes = scene.nodes.map { node -> Node in
            let lane = nodeLanes[node.id] ?? 0
            let y = (Double(lane) + (1 - laneSpread) / 2 + laneSpread * node.point.y) / count
            return Node(id: node.id, name: node.name, depth: node.depth, isRoot: node.isRoot, hasMore: node.hasMore,
                        point: .init(x: node.point.x, y: y), lane: lanes[lane].title)
        }
        let edges = scene.edges.map { edge -> Edge in
            var edge = edge
            edge.lane = lanes[edgeLanes[edge.factID] ?? 0].title
            return edge
        }
        return Scene(rootID: scene.rootID, nodes: nodes, edges: edges, isTruncated: scene.isTruncated, cycles: scene.cycles,
                     lanes: lanes)
    }

    /// The lane most of a node's shown relationships belong to, the earlier
    /// lane on a tie, and the first lane for a node with none.
    private static func homeLane(of id: UUID, scene: Scene, edgeLanes: [UUID: Int]) -> Int {
        var counts: [Int: Int] = [:]
        for edge in scene.edges(touching: id) { counts[edgeLanes[edge.factID] ?? 0, default: 0] += 1 }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? 0
    }

    private static func laneID(_ context: KnowledgeBrowserContext) -> String { context.id?.uuidString ?? "unknown" }

    private static func laneOrder(_ lhs: KnowledgeBrowserContext, _ rhs: KnowledgeBrowserContext) -> Bool {
        let kinds = KnowledgeContextKind.allCases
        let left = kinds.firstIndex(of: lhs.kind) ?? kinds.count, right = kinds.firstIndex(of: rhs.kind) ?? kinds.count
        guard left == right else { return left < right }
        let leftTitle = lane(lhs).title, rightTitle = lane(rhs).title
        return leftTitle == rightTitle ? laneID(lhs) < laneID(rhs) : leftTitle.localizedStandardCompare(rightTitle) == .orderedAscending
    }

    private static func lane(_ context: KnowledgeBrowserContext) -> Lane {
        let kind = kindName(context.kind)
        let name = context.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Lane(id: laneID(context), title: name.isEmpty ? kind : name, detail: name.isEmpty ? nil : kind)
    }

    /// A context kind in words.
    static func kindName(_ kind: KnowledgeContextKind) -> String { copy("context_kind." + kind.rawValue) }
}

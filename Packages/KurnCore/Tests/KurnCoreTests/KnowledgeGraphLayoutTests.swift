import Foundation
import Testing
@testable import KurnCore

/// K4.2: a deterministic layout that keeps fixed positions where they were.
struct KnowledgeGraphLayoutTests {
    private typealias Layout = KnowledgeGraphLayout

    private struct Builder {
        var entities: [KnowledgeWikiSnapshot.Entity] = []
        var facts: [KnowledgeWikiSnapshot.Fact] = []

        mutating func entity(_ name: String) -> UUID {
            let id = UUID()
            entities.append(.init(id: id, kind: .project, name: name))
            return id
        }

        mutating func relate(_ subject: UUID, _ object: UUID) {
            facts.append(.init(
                id: UUID(), subjectID: subject, predicate: .relatesTo, objectID: object,
                qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted),
                source: .init(meetingID: UUID(), recordedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ])))
        }

        func graph(root: UUID, depth: Int = 2) throws -> KnowledgeGraph {
            let index = KnowledgeGraphIndex(pages: try KnowledgeWikiProjector.project(.init(revision: 1, entities: entities, facts: facts)))
            return try #require(index.query(.init(rootID: root, depth: depth)))
        }
    }

    private static func distance(_ lhs: Layout.Point?, _ rhs: Layout.Point?) throws -> Double {
        let first = try #require(lhs), second = try #require(rhs)
        return ((first.x - second.x) * (first.x - second.x) + (first.y - second.y) * (first.y - second.y)).squareRoot()
    }

    private struct Star {
        let graph: KnowledgeGraph
        let root: UUID
        let spokes: [UUID]
        let far: UUID
    }

    /// A root with five spokes and a chain hanging off the first.
    private static func star() throws -> Star {
        var builder = Builder()
        let root = builder.entity("Root")
        let spokes = (0..<5).map { builder.entity("Spoke \($0)") }
        for spoke in spokes { builder.relate(root, spoke) }
        let far = builder.entity("Far")
        builder.relate(spokes[0], far)
        return Star(graph: try builder.graph(root: root), root: root, spokes: spokes, far: far)
    }

    @Test func theSameGraphAndSeedGiveTheSameLayout() throws {
        let star = try Self.star()
        let first = Layout.layout(star.graph, seed: 7)
        #expect(first == Layout.layout(star.graph, seed: 7))
        #expect(first.positions.count == star.graph.nodes.count)
        let other = Layout.layout(star.graph, seed: 8)
        #expect(other.positions[star.spokes[1]] != first.positions[star.spokes[1]])
        // Node and edge order make no difference.
        let shuffled = KnowledgeGraph(query: star.graph.query, nodes: Array(star.graph.nodes.reversed()), edges: Array(star.graph.edges.reversed()),
                                      isTruncated: false, frontier: [], supersessionCycles: [])
        #expect(Layout.layout(shuffled, seed: 7) == first)
    }

    @Test func theRootIsCentredAndEveryNodeStaysInsideTheMargins() throws {
        let star = try Self.star()
        let layout = Layout.layout(star.graph)
        #expect(layout.positions[star.root] == Layout.Point(x: 0.5, y: 0.5))
        for point in layout.positions.values {
            #expect(point.x >= Layout.margin && point.x <= 1 - Layout.margin)
            #expect(point.y >= Layout.margin && point.y <= 1 - Layout.margin)
        }
        let points = Array(layout.positions.values)
        for first in points.indices {
            for second in points.indices where second > first {
                #expect(try Self.distance(points[first], points[second]) > 0.02)
            }
        }
    }

    @Test func aSecondHopSitsFartherFromTheRootThanItsNeighbour() throws {
        let star = try Self.star()
        let layout = Layout.layout(star.graph)
        let near = try Self.distance(layout.positions[star.root], layout.positions[star.spokes[0]])
        let far = try Self.distance(layout.positions[star.root], layout.positions[star.far])
        #expect(far > near)
    }

    @Test func fixedPositionsStayPutWhileNewNodesArePlaced() throws {
        var builder = Builder()
        let root = builder.entity("Root"), first = builder.entity("First"), second = builder.entity("Second")
        builder.relate(root, first)
        builder.relate(root, second)
        let before = Layout.layout(try builder.graph(root: root, depth: 1))
        let added = builder.entity("Added")
        builder.relate(first, added)
        let grown = try builder.graph(root: root)
        let after = Layout.layout(grown, fixed: before.positions)
        for (id, point) in before.positions { #expect(after.positions[id] == point) }
        let placed = try #require(after.positions[added])
        for (_, point) in before.positions { #expect(try Self.distance(point, placed) > 0.02) }
        // A fixed root is not pulled back to the centre.
        let moved = Layout.layout(grown, fixed: [root: Layout.Point(x: 0.2, y: 0.3)])
        #expect(moved.positions[root] == Layout.Point(x: 0.2, y: 0.3))
        // Out-of-range fixed positions are kept inside the margins.
        let outside = Layout.layout(grown, fixed: [first: Layout.Point(x: -4, y: 9)])
        #expect(outside.positions[first] == Layout.Point(x: Layout.margin, y: 1 - Layout.margin))
    }

    @Test func aLoneRootSitsInTheCentre() throws {
        var builder = Builder()
        let root = builder.entity("Root"), other = builder.entity("Other")
        builder.relate(root, other)
        let graph = try builder.graph(root: root, depth: 0)
        #expect(Layout.layout(graph).positions == [root: Layout.Point(x: 0.5, y: 0.5)])
        let empty = KnowledgeGraph(query: .init(rootID: root), nodes: [], edges: [], isTruncated: false, frontier: [], supersessionCycles: [])
        #expect(Layout.layout(empty).positions.isEmpty)
        #expect(Layout.layout(graph, iterations: 0).positions[root] == Layout.Point(x: 0.5, y: 0.5))
    }

    @Test func theHashIsStableAcrossRuns() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(Layout.hash(0, id) == Layout.hash(0, id))
        #expect(Layout.hash(0, id) != Layout.hash(1, id))
    }
}

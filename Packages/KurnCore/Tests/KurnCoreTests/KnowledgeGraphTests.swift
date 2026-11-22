import Foundation
import Testing
@testable import KurnCore

/// K4.1: a bounded, deterministic neighbourhood of the relationship graph.
struct KnowledgeGraphTests {
    private typealias Timeline = KnowledgeFixtureTimeline
    private typealias Query = KnowledgeGraph.Query

    @Test func theProjectsBlockerIsOneHopAwayAndTheSupersessionIsNot() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let index = KnowledgeGraphIndex(pages: try KnowledgeWikiProjector.project(line.snapshot))
        let project = try #require(line.entities["e1"]), team = try #require(line.entities["e4"])
        let graph = try #require(index.query(Query(rootID: project)))
        #expect(graph.nodes.map(\.id) == [project, team])
        #expect(graph.nodes.map(\.depth) == [0, 1])
        let edge = try #require(graph.edges.first)
        #expect(graph.edges.count == 1 && edge.factID == line.assertions["a6"])
        #expect(edge.sourceID == team && edge.targetID == project && edge.predicate == .blocks)
        #expect(edge.evidenceID != nil)
        #expect(!graph.isTruncated && graph.frontier.isEmpty && graph.supersessionCycles.isEmpty)
        let decision = try #require(line.entities["e2"]), initiative = try #require(line.entities["e5"])
        let replaced = try #require(index.query(Query(rootID: decision)))
        #expect(replaced.nodes.map(\.id) == [decision, initiative])
        #expect(replaced.edges.map(\.predicate) == [.supersedes])
        #expect(index.query(Query(rootID: UUID())) == nil)
    }

    // MARK: - Synthetic

    private struct Builder {
        var entities: [KnowledgeWikiSnapshot.Entity] = []
        var facts: [KnowledgeWikiSnapshot.Fact] = []

        mutating func entity(_ name: String, kind: KnowledgeEntityKind = .project, mergedInto: UUID? = nil) -> UUID {
            let id = UUID()
            entities.append(.init(id: id, kind: kind, name: name, targetID: mergedInto))
            return id
        }

        @discardableResult
        mutating func fact(_ subject: UUID, _ predicate: KnowledgePredicate, _ object: UUID,
                           modality: KnowledgeModality = .reported, polarity: KnowledgePolarity = .positive) -> UUID {
            let id = UUID()
            facts.append(.init(
                id: id, subjectID: subject, predicate: predicate, objectID: object,
                qualifiers: .init(modality: modality, polarity: polarity, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted),
                source: .init(meetingID: UUID(), recordedAt: Timeline.date("2026-03-01"), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ])))
            return id
        }

        func index() throws -> KnowledgeGraphIndex {
            KnowledgeGraphIndex(pages: try KnowledgeWikiProjector.project(.init(revision: 1, entities: entities, facts: facts)))
        }
    }

    @Test func depthBoundsTheWalkAndMarksWhereItCouldGoOn() throws {
        var graph = Builder()
        let root = graph.entity("Root"), near = graph.entity("Near"), far = graph.entity("Far"), farther = graph.entity("Farther")
        graph.fact(root, .dependsOn, near)
        graph.fact(near, .dependsOn, far)
        graph.fact(far, .dependsOn, farther)
        let index = try graph.index()
        let one = try #require(index.query(Query(rootID: root)))
        #expect(one.nodes.map(\.id) == [root, near] && one.edges.count == 1)
        // The depth bound is what was asked: not a truncation, but Near has more.
        #expect(!one.isTruncated && one.frontier == [near])
        let two = try #require(index.query(Query(rootID: root, depth: 5)))
        #expect(two.query.depth == Query.maximumDepth)
        #expect(two.nodes.map(\.id) == [root, near, far] && two.nodes.map(\.depth) == [0, 1, 2])
        #expect(two.frontier == [far])
        let zero = try #require(index.query(Query(rootID: root, depth: 0)))
        #expect(zero.nodes.map(\.id) == [root] && zero.edges.isEmpty && zero.frontier == [root])
    }

    @Test func nodeAndEdgeBoundsTruncateAndKeepTheNearestFirst() throws {
        var graph = Builder()
        let root = graph.entity("Root")
        let spokes = (0..<5).map { graph.entity("Spoke \($0)") }
        for spoke in spokes { graph.fact(root, .relatesTo, spoke) }
        graph.fact(spokes[0], .relatesTo, spokes[1])
        let index = try graph.index()
        let few = try #require(index.query(Query(rootID: root, maxNodes: 3)))
        #expect(few.nodes.count == 3 && few.isTruncated)
        #expect(few.frontier.contains(root))
        let shown = Set(few.nodes.map(\.id))
        #expect(few.edges.allSatisfy { shown.contains($0.sourceID) && shown.contains($0.targetID) })
        let all = try #require(index.query(Query(rootID: root)))
        #expect(all.nodes.count == 6 && all.edges.count == 6 && !all.isTruncated && all.frontier.isEmpty)
        let fewEdges = try #require(index.query(Query(rootID: root, maxEdges: 2)))
        #expect(fewEdges.edges.count == 2 && fewEdges.isTruncated && fewEdges.nodes.count == 6)
        // Two of six claims shown: the root and at least three spokes have more.
        #expect(fewEdges.frontier.contains(root) && fewEdges.frontier.count >= 4)
        #expect(Query(rootID: root, maxNodes: 0, maxEdges: -1).maxNodes == 1)
        #expect(Query(rootID: root, maxNodes: 500, maxEdges: 500).maxEdges == Query.maximumEdges)
    }

    @Test func filtersFollowOnlyTheClaimsAsked() throws {
        var graph = Builder()
        let root = graph.entity("Root"), owner = graph.entity("Owner", kind: .team), idea = graph.entity("Idea")
        let rival = graph.entity("Rival")
        graph.fact(owner, .owns, root)
        graph.fact(root, .relatesTo, idea, modality: .proposed)
        graph.fact(root, .opposes, rival, polarity: .negative)
        let index = try graph.index()
        let everything = try #require(index.query(Query(rootID: root)))
        #expect(everything.nodes.count == 4 && everything.edges.contains { $0.isTentative })
        let owned = try #require(index.query(Query(rootID: root, predicates: [.owns])))
        #expect(owned.nodes.map(\.id) == [root, owner] && owned.frontier.isEmpty)
        let established = try #require(index.query(Query(rootID: root, includesTentative: false, includesNegated: false)))
        #expect(Set(established.nodes.map(\.id)) == [root, owner])
        let guess = graph.entity("Guess")
        graph.fact(root, .dependsOn, guess, modality: .inferred)
        let inferred = try graph.index()
        #expect(try #require(inferred.query(Query(rootID: root))).nodes.contains { $0.id == guess })
        let stated = try #require(inferred.query(Query(rootID: root, includesInferred: false)))
        #expect(!stated.nodes.contains { $0.id == guess } && stated.nodes.count == 4 && stated.frontier.isEmpty)
    }

    @Test func aMergedIdentityIsOneNodeAndItsOwnLoopIsNotAnEdge() throws {
        var graph = Builder()
        let kept = graph.entity("Portal"), team = graph.entity("Platform", kind: .team)
        let merged = graph.entity("Portal v2", mergedInto: kept)
        graph.fact(merged, .dependsOn, team)
        graph.fact(merged, .relatesTo, kept)
        let index = try graph.index()
        let result = try #require(index.query(Query(rootID: kept)))
        #expect(result.nodes.map(\.id) == [kept, team] && result.edges.count == 1)
        #expect(result.edges.first?.sourceID == kept)
    }

    @Test func supersessionCyclesAreReportedNotOrdered() throws {
        var graph = Builder()
        let first = graph.entity("First", kind: .decisionThread), second = graph.entity("Second", kind: .decisionThread)
        let third = graph.entity("Third", kind: .decisionThread), apart = graph.entity("Apart", kind: .decisionThread)
        let alone = graph.entity("Alone", kind: .decisionThread), loop = graph.entity("Loop", kind: .decisionThread)
        let looped = graph.entity("Loop again", kind: .decisionThread, mergedInto: loop)
        graph.fact(second, .supersedes, first)
        graph.fact(third, .supersedes, second)
        graph.fact(first, .supersedes, third)
        // A tentative or negated replacement closes no cycle.
        graph.fact(apart, .supersedes, alone)
        graph.fact(alone, .supersedes, apart, modality: .proposed)
        graph.fact(alone, .supersedes, apart, polarity: .negative)
        // After the merge, Loop supersedes itself.
        graph.fact(looped, .supersedes, loop)
        graph.fact(loop, .relatesTo, alone)
        let index = try graph.index()
        let cycle = try #require(index.query(Query(rootID: first)))
        #expect(cycle.supersessionCycles == [[first, second, third].sorted { $0.uuidString < $1.uuidString }])
        let apartGraph = try #require(index.query(Query(rootID: apart, depth: 0)))
        #expect(apartGraph.supersessionCycles.isEmpty)
        let loopGraph = try #require(index.query(Query(rootID: loop, depth: 0)))
        #expect(loopGraph.supersessionCycles == [[loop]])
    }

    @Test func theAnswerDoesNotDependOnPageOrder() throws {
        var graph = Builder()
        let root = graph.entity("Root")
        let others = (0..<6).map { graph.entity("Other \($0)") }
        for (offset, other) in others.enumerated() {
            if offset.isMultiple(of: 2) { graph.fact(root, .relatesTo, other) } else { graph.fact(other, .relatesTo, root) }
        }
        graph.fact(others[1], .dependsOn, others[2])
        let pages = try KnowledgeWikiProjector.project(.init(revision: 1, entities: graph.entities, facts: graph.facts))
        let query = Query(rootID: root, depth: 2, maxNodes: 4, maxEdges: 3)
        #expect(KnowledgeGraphIndex(pages: pages).query(query) == KnowledgeGraphIndex(pages: pages.reversed()).query(query))
    }
}

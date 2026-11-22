import CoreGraphics
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K4.3: what the Graph Explorer draws and lists, and the exploration it keeps.
@MainActor
struct KnowledgeGraphPresentationTests {
    private static let meeting = UUID(), project = UUID(), team = UUID(), owner = UUID(), idea = UUID()

    private static func read(withOwner: Bool = true) throws -> KnowledgeBrowserRead {
        func fact(_ subject: UUID, _ predicate: KnowledgePredicate, _ object: UUID, modality: KnowledgeModality = .reported,
                  polarity: KnowledgePolarity = .positive) -> KnowledgeWikiSnapshot.Fact {
            KnowledgeWikiSnapshot.Fact(
                id: UUID(), subjectID: subject, predicate: predicate, objectID: object,
                qualifiers: .init(modality: modality, polarity: polarity, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted),
                source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ]))
        }
        var entities: [KnowledgeWikiSnapshot.Entity] = [
            .init(id: project, kind: .project, name: "Portal"), .init(id: team, kind: .team, name: "Platform"),
            .init(id: idea, kind: .project, name: "Idea"),
        ]
        var facts = [fact(team, .blocks, project), fact(project, .relatesTo, idea, modality: .proposed),
                     fact(project, .dependsOn, team, polarity: .negative)]
        if withOwner {
            entities.append(.init(id: owner, kind: .team, name: "Owners"))
            facts.append(fact(owner, .owns, team))
        }
        return try KnowledgeBrowserRead(meetingIDs: [meeting], wiki: .init(revision: 1, entities: entities, facts: facts),
                                        meetingTitles: [meeting: "Weekly"], policyRevisionKey: "p1")
    }

    private static func scene(root: UUID = project, depth: Int = 1) throws -> KnowledgeGraphPresentation.Scene {
        let service = KnowledgeGraphQueryService()
        var options = KnowledgeGraphPresentation.Options()
        options.depth = depth
        let laidOut = try #require(service.laidOut(options.query(root: root), in: try read()))
        return KnowledgeGraphPresentation.scene(laidOut.graph, layout: laidOut.layout)
    }

    @Test func theSceneShowsNodesEdgesAndWhatIsLeftOut() throws {
        let scene = try Self.scene()
        #expect(scene.rootID == Self.project)
        #expect(scene.nodes.first?.id == Self.project && scene.nodes.first?.isRoot == true)
        #expect(Set(scene.nodes.map(\.id)) == [Self.project, Self.team, Self.idea])
        #expect(scene.nodes.allSatisfy { $0.point.x > 0 && $0.point.x < 1 && $0.point.y > 0 && $0.point.y < 1 })
        // Platform also has the claim Owners makes about it, which depth 1 leaves out.
        #expect(scene.node(Self.team)?.hasMore == true && scene.node(Self.idea)?.hasMore == false)
        #expect(scene.edges.count == 3 && !scene.isTruncated && scene.cycles.isEmpty)
        let blocks = try #require(scene.edges.first { $0.sourceID == Self.team && $0.targetID == Self.project })
        // In its stated direction: the subject comes first.
        let subject = try #require(blocks.text.range(of: "Platform")), object = try #require(blocks.text.range(of: "Portal"))
        #expect(subject.lowerBound < object.lowerBound)
        if case .evidence(let assertionID, _)? = blocks.evidence { #expect(assertionID == blocks.factID) } else {
            Issue.record("A claim with evidence opens its passage")
        }
        let proposed = try #require(scene.edges.first { $0.targetID == Self.idea })
        #expect(proposed.isTentative && KnowledgeGraphPresentation.notes(proposed).count == 1)
        #expect(KnowledgeGraphPresentation.notes(blocks).isEmpty)
        let denied = try #require(scene.edges.first { $0.isNegated })
        let predicate = NSLocalizedString("knowledge.predicate.dependsOn", comment: "")
        let plain = String(format: NSLocalizedString("detail.knowledge.claim", comment: ""), "Portal", predicate, "Platform")
        #expect(denied.text == String(format: NSLocalizedString("detail.knowledge.negative_claim", comment: ""), plain))
        #expect(scene.edges(touching: Self.idea).map(\.factID) == [proposed.factID])
        #expect(scene.summary.contains("3"))
    }

    @Test func listSectionsAndLabelsDescribeEveryNode() throws {
        let scene = try Self.scene(depth: 2)
        let sections = KnowledgeGraphPresentation.listSections(scene)
        #expect(sections.map(\.id) == scene.nodes.map(\.id))
        #expect(sections.first?.edges.count == 3)
        let team = try #require(scene.node(Self.team))
        let label = KnowledgeGraphPresentation.label(team, scene: scene)
        // Blocks, the denied dependency and the ownership.
        #expect(label.hasPrefix("Platform") && label.contains("3"))
        let root = try #require(scene.node(Self.project))
        #expect(KnowledgeGraphPresentation.label(root, scene: scene).hasPrefix("Portal"))
        let point = KnowledgeGraphPresentation.point(.init(x: 0.25, y: 0.5), in: CGSize(width: 200, height: 100))
        #expect(point == CGPoint(x: 50, y: 50))
    }

    @Test func aSupersessionLoopIsNamed() throws {
        let meeting = UUID(), first = UUID(), second = UUID(), third = UUID(), fourth = UUID()
        func supersedes(_ subject: UUID, _ object: UUID) -> KnowledgeWikiSnapshot.Fact {
            .init(id: UUID(), subjectID: subject, predicate: .supersedes, objectID: object,
                  qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                    confidence: .medium, review: .machineExtracted),
                  source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: [
                      .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                            attributedSpeaker: "Speaker 1"),
                  ]))
        }
        let read = try KnowledgeBrowserRead(
            meetingIDs: [meeting],
            wiki: .init(revision: 1, entities: [.init(id: first, kind: .decisionThread, name: "First"),
                                                .init(id: second, kind: .decisionThread, name: "Second"),
                                                .init(id: third, kind: .decisionThread, name: "Third"),
                                                .init(id: fourth, kind: .decisionThread, name: "Fourth")],
                        facts: [supersedes(first, second), supersedes(second, third), supersedes(third, fourth), supersedes(fourth, first)]),
            meetingTitles: [meeting: "Weekly"])
        // At distance 1, Third is not drawn but the loop still names it.
        let laidOut = try #require(KnowledgeGraphQueryService().laidOut(.init(rootID: first), in: read))
        #expect(!laidOut.graph.nodes.contains { $0.id == third })
        let scene = KnowledgeGraphPresentation.scene(laidOut.graph, layout: laidOut.layout, pages: read.pages)
        #expect(scene.cycles.count == 1 && Set(scene.cycles[0]) == ["First", "Second", "Third", "Fourth"])
    }

    @Test func theExplorationIsKeptAndFallsBackToWhereItWasOpened() throws {
        let service = KnowledgeGraphQueryService()
        var exploration = service.exploration(from: Self.project)
        #expect(exploration.root == Self.project && exploration.selected == Self.project && exploration.showsList == nil)
        exploration.selected = Self.idea
        exploration.options.includesTentative = false
        service.remember(exploration, from: Self.project)
        #expect(service.exploration(from: Self.project) == exploration)
        #expect(service.exploration(from: Self.team).root == Self.team)
        // The filter is applied: the proposed claim and its node are gone.
        let filtered = try #require(service.laidOut(exploration, from: Self.project, in: try Self.read()))
        #expect(!filtered.graph.nodes.contains { $0.id == Self.idea })
        exploration.recentre(on: Self.owner)
        #expect(exploration.root == Self.owner && exploration.selected == Self.owner)
        service.remember(exploration, from: Self.project)
        let centred = try #require(service.laidOut(exploration, from: Self.project, in: try Self.read()))
        #expect(centred.graph.query.rootID == Self.owner)
        // Owners is no longer in the read: the graph centres where it was opened.
        let fallback = try #require(service.laidOut(exploration, from: Self.project, in: try Self.read(withOwner: false)))
        #expect(fallback.graph.query.rootID == Self.project)
        #expect(service.laidOut(KnowledgeGraphPresentation.Exploration(root: UUID()), from: UUID(), in: try Self.read()) == nil)
        service.clear()
        #expect(service.exploration(from: Self.project) == KnowledgeGraphPresentation.Exploration(root: Self.project))
    }
}

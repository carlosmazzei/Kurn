import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K4.3: the Graph Explorer's context lanes mode.
@MainActor
struct KnowledgeGraphLanesPresentationTests {
    private typealias Presentation = KnowledgeGraphPresentation
    private static let weekly = UUID(), vendorCall = UUID(), loose = UUID()
    private static let internalContext = UUID(), vendorContext = UUID()
    private static let project = UUID(), team = UUID(), vendor = UUID(), other = UUID()
    private static let blocker = UUID(), dependency = UUID(), looseClaim = UUID()

    private static func read(contexts: [UUID: KnowledgeBrowserContext]? = nil) throws -> KnowledgeBrowserRead {
        func fact(_ id: UUID, _ subject: UUID, _ predicate: KnowledgePredicate, _ object: UUID, meeting: UUID) -> KnowledgeWikiSnapshot.Fact {
            KnowledgeWikiSnapshot.Fact(
                id: id, subjectID: subject, predicate: predicate, objectID: object,
                qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted),
                source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_700_000_000), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ]))
        }
        let entities: [KnowledgeWikiSnapshot.Entity] = [
            .init(id: project, kind: .project, name: "Portal"), .init(id: team, kind: .team, name: "Platform"),
            .init(id: vendor, kind: .organization, name: "Vendor"), .init(id: other, kind: .organization, name: "Other"),
        ]
        let facts = [fact(blocker, team, .blocks, project, meeting: weekly),
                     fact(dependency, project, .dependsOn, vendor, meeting: vendorCall),
                     fact(looseClaim, project, .dependsOn, other, meeting: loose)]
        let defaults: [UUID: KnowledgeBrowserContext] = [
            weekly: .init(id: internalContext, kind: .internalMeeting, name: "  "),
            vendorCall: .init(id: vendorContext, kind: .vendorDiscussion, name: "Example vendor sync"),
        ]
        return try KnowledgeBrowserRead(meetingIDs: [weekly, vendorCall, loose], wiki: .init(revision: 1, entities: entities, facts: facts),
                                        meetingTitles: [weekly: "Weekly", vendorCall: "Vendor call", loose: "Loose"],
                                        meetingContexts: contexts ?? defaults)
    }

    private static func scenes(_ read: KnowledgeBrowserRead) throws -> (plain: Presentation.Scene, laned: Presentation.Scene) {
        let laidOut = try #require(KnowledgeGraphQueryService().laidOut(Presentation.Options().query(root: project), in: read))
        let plain = Presentation.scene(laidOut.graph, layout: laidOut.layout, pages: read.pages)
        return (plain, Presentation.laned(plain, pages: read.pages, contexts: read.meetingContexts))
    }

    @Test func lanesFollowKindOrderWithTheUnknownContextLast() throws {
        let (_, laned) = try Self.scenes(try Self.read())
        let internalName = Presentation.kindName(.internalMeeting)
        // An unnamed context is titled by its kind; a named one keeps its kind as detail.
        #expect(laned.lanes == [
            .init(id: Self.internalContext.uuidString, title: internalName, detail: nil),
            .init(id: Self.vendorContext.uuidString, title: "Example vendor sync", detail: Presentation.kindName(.vendorDiscussion)),
            .init(id: "unknown", title: Presentation.kindName(.unknown), detail: nil),
        ])
        let lanes = Dictionary(uniqueKeysWithValues: laned.edges.map { ($0.factID, $0.lane) })
        #expect(lanes == [Self.blocker: internalName, Self.dependency: "Example vendor sync",
                          Self.looseClaim: Presentation.kindName(.unknown)])
        let note = String(format: Presentation.copy("in_context"), "Example vendor sync")
        let edge = try #require(laned.edges.first { $0.factID == Self.dependency })
        #expect(Presentation.notes(edge) == [note])
    }

    @Test func eachNodeSitsInItsMainLaneAndKeepsItsPlaceAcross() throws {
        let (plain, laned) = try Self.scenes(try Self.read())
        func band(_ id: UUID) throws -> Int {
            let node = try #require(laned.node(id))
            return Int(node.point.y * Double(laned.lanes.count))
        }
        // The project has one relationship in each lane: the first lane wins the tie.
        #expect(try band(Self.project) == 0)
        #expect(try band(Self.team) == 0)
        #expect(try band(Self.vendor) == 1)
        #expect(try band(Self.other) == 2)
        for node in laned.nodes {
            let before = try #require(plain.node(node.id))
            #expect(node.point.x == before.point.x)
            let lane = try Double(band(node.id))
            let inside = (node.point.y * Double(laned.lanes.count) - lane)
            #expect(inside >= (1 - Presentation.laneSpread) / 2 - 1e-9 && inside <= (1 + Presentation.laneSpread) / 2 + 1e-9)
        }
        let vendor = try #require(laned.node(Self.vendor))
        #expect(Presentation.label(vendor, scene: laned).contains("Example vendor sync"))
        #expect(laned.nodes.map(\.id) == plain.nodes.map(\.id) && laned.isTruncated == plain.isTruncated)
    }

    @Test func meetingsWithoutAContextShareTheUnknownLane() throws {
        let (plain, laned) = try Self.scenes(try Self.read(contexts: [:]))
        #expect(laned.lanes.map(\.id) == ["unknown"])
        #expect(laned.edges.allSatisfy { $0.lane == Presentation.kindName(.unknown) })
        // One lane spreads nodes over its middle, keeping their order.
        let order = plain.nodes.sorted { $0.point.y < $1.point.y }.map(\.id)
        #expect(laned.nodes.sorted { $0.point.y < $1.point.y }.map(\.id) == order)
        #expect(plain.lanes.isEmpty && plain.edges.allSatisfy { $0.lane == nil })
    }

    @Test func aSceneWithoutRelationshipsIsLeftAsItIs() throws {
        let read = try Self.read()
        let laidOut = try #require(KnowledgeGraphQueryService().laidOut(Presentation.Options().query(root: Self.project), in: read))
        let empty = Presentation.scene(laidOut.graph, layout: laidOut.layout, pages: read.pages, states: [:])
        #expect(empty.edges.isEmpty)
        #expect(Presentation.laned(empty, pages: read.pages, contexts: read.meetingContexts) == empty)
    }

    @Test func theReadRefusesAContextOutsideItsMeetings() throws {
        #expect(throws: KnowledgeWikiStoreError.self) {
            try Self.read(contexts: [UUID(): .unknown])
        }
    }

    @Test func theModeShowsEveryRelationshipAndSaysWhatTheLanesMean() throws {
        let read = try Self.read()
        var exploration = Presentation.Exploration(root: Self.project)
        exploration.mode = .lanes
        let laidOut = try #require(KnowledgeGraphQueryService().laidOut(exploration.options.query(root: Self.project), in: read))
        let days = Presentation.days(exploration, pages: read.pages, entityID: Self.project, now: Date())
        #expect(Presentation.states(exploration, graph: laidOut.graph, pages: read.pages, days: days) == nil)
        #expect(Presentation.legend(.lanes) == Presentation.copy("mode.lanes.footer"))
        let names = KnowledgeContextKind.allCases.map(Presentation.kindName)
        #expect(Set(names).count == names.count && names.allSatisfy { !$0.isEmpty && !$0.hasPrefix("knowledge.graph.") })
    }
}

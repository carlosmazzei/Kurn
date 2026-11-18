import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K4.1: graph answers are cached per read scope and never outlive it.
@MainActor
struct KnowledgeGraphQueryServiceTests {
    private static let meeting = UUID(), project = UUID(), team = UUID(), owner = UUID()

    private static func read(revision: Int = 1, withOwner: Bool = false, policy: String = "p1",
                             withBlocker: Bool = true) throws -> KnowledgeBrowserRead {
        func fact(_ subject: UUID, _ predicate: KnowledgePredicate, _ object: UUID) -> KnowledgeWikiSnapshot.Fact {
            KnowledgeWikiSnapshot.Fact(
                id: UUID(), subjectID: subject, predicate: predicate, objectID: object,
                qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted),
                source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ]))
        }
        var entities: [KnowledgeWikiSnapshot.Entity] = [
            .init(id: project, kind: .project, name: "Portal"), .init(id: team, kind: .team, name: "Platform"),
        ]
        // Without the blocker the team still has a page, through the claim it owns.
        var facts = withBlocker ? [fact(team, .blocks, project)] : [fact(team, .owns, owner)]
        if withOwner || !withBlocker { entities.append(.init(id: owner, kind: .team, name: "Owners")) }
        if withOwner { facts.append(fact(owner, .owns, project)) }
        return try KnowledgeBrowserRead(meetingIDs: [meeting], wiki: .init(revision: revision, entities: entities, facts: facts),
                                        meetingTitles: [meeting: "Weekly"], policyRevisionKey: policy)
    }

    @Test func answersAreReusedWithinOneReadScope() throws {
        let service = KnowledgeGraphQueryService()
        let read = try Self.read()
        let query = KnowledgeGraph.Query(rootID: Self.project)
        let first = try #require(service.graph(query, in: read))
        #expect(first.nodes.map(\.id) == [Self.project, Self.team])
        #expect(service.graph(query, in: read) == first)
        #expect(service.indexBuilds == 1 && service.cachedAnswerCount == 1)
        #expect(service.graph(.init(rootID: UUID()), in: read) == nil)
        #expect(service.cachedAnswerCount == 2 && service.indexBuilds == 1)
    }

    @Test func aNewerRevisionPolicyOrScopeIsNeverAnsweredFromTheOldOne() throws {
        let service = KnowledgeGraphQueryService()
        let query = KnowledgeGraph.Query(rootID: Self.project)
        _ = service.graph(query, in: try Self.read())
        let newer = try #require(service.graph(query, in: try Self.read(revision: 2, withOwner: true)))
        #expect(newer.nodes.count == 3 && service.indexBuilds == 2 && service.cachedAnswerCount == 1)
        _ = service.graph(query, in: try Self.read(revision: 2, withOwner: true, policy: "p2"))
        #expect(service.indexBuilds == 3 && service.scope?.policyRevisionKey == "p2")
        service.clear()
        #expect(service.scope == nil && service.cachedAnswerCount == 0)
        _ = service.graph(query, in: try Self.read())
        #expect(service.indexBuilds == 4)
    }

    @Test func pagesThatChangedWithoutANewRevisionAreReindexed() throws {
        // A corrected transcript can drop a claim without a new canonical revision.
        let service = KnowledgeGraphQueryService()
        let query = KnowledgeGraph.Query(rootID: Self.team)
        let before = try #require(service.graph(query, in: try Self.read(withOwner: true)))
        #expect(before.edges.contains { $0.predicate == .blocks })
        // Same revision, meetings, policy and page count: only the pages differ.
        let corrected = try Self.read(withOwner: true, withBlocker: false)
        let original = try Self.read(withOwner: true)
        #expect(corrected.pages.count == original.pages.count)
        let after = try #require(service.graph(query, in: corrected))
        #expect(!after.edges.contains { $0.predicate == .blocks } && service.indexBuilds == 2)
        let fresh = try #require(service.graph(.init(rootID: Self.project), in: corrected))
        #expect(!fresh.edges.contains { $0.predicate == .blocks })
    }

    @Test func theLeastRecentlyAskedAnswerIsForgottenFirst() throws {
        let service = KnowledgeGraphQueryService(capacity: 2)
        let read = try Self.read()
        let one = KnowledgeGraph.Query(rootID: Self.project), two = KnowledgeGraph.Query(rootID: Self.team)
        let three = KnowledgeGraph.Query(rootID: Self.project, depth: 0)
        _ = service.graph(one, in: read)
        _ = service.graph(two, in: read)
        _ = service.graph(one, in: read)
        _ = service.graph(three, in: read)
        #expect(service.cachedAnswerCount == 2)
        // `two` was evicted; asking again recomputes it from the same index.
        #expect(service.graph(two, in: read)?.nodes.map(\.id) == [Self.team, Self.project])
        #expect(service.indexBuilds == 1 && KnowledgeGraphQueryService(capacity: 0).capacity == 1)
    }

    @Test func layoutsAreCachedAndKeepNodesWhereTheyWereShown() throws {
        let service = KnowledgeGraphQueryService(capacity: 1)
        let read = try Self.read(withOwner: true)
        let alone = try #require(service.laidOut(.init(rootID: Self.project, depth: 0), in: read))
        #expect(alone.layout.positions == [Self.project: KnowledgeGraphLayout.Point(x: 0.5, y: 0.5)])
        let grown = try #require(service.laidOut(.init(rootID: Self.project), in: read))
        #expect(grown.layout.positions.count == 3)
        #expect(grown.layout.positions[Self.project] == KnowledgeGraphLayout.Point(x: 0.5, y: 0.5))
        let teamPoint = try #require(grown.layout.positions[Self.team])
        // Asked again, the same layout comes back from the cache.
        #expect(service.laidOut(.init(rootID: Self.project), in: read)?.layout == grown.layout)
        // Re-rooting on the team keeps it where it was shown instead of centring it.
        let rerooted = try #require(service.laidOut(.init(rootID: Self.team), in: read))
        #expect(rerooted.layout.positions[Self.team] == teamPoint)
        #expect(service.laidOut(.init(rootID: UUID()), in: read) == nil)
        #expect(service.shownPositions.count == 3)
        // A new scope or a clear forgets every shown position.
        _ = service.graph(.init(rootID: Self.project), in: try Self.read(revision: 2, withOwner: true))
        #expect(service.shownPositions.isEmpty)
        _ = service.laidOut(.init(rootID: Self.project), in: read)
        service.clear()
        #expect(service.shownPositions.isEmpty && service.cachedAnswerCount == 0)
    }
}

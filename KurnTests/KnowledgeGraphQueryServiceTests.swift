import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K4.1: graph answers are cached per read scope and never outlive it.
@MainActor
struct KnowledgeGraphQueryServiceTests {
    private static let meeting = UUID(), project = UUID(), team = UUID(), owner = UUID()

    private static func read(revision: Int = 1, withOwner: Bool = false, policy: String = "p1") throws -> KnowledgeBrowserRead {
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
        var facts = [fact(team, .blocks, project)]
        if withOwner {
            entities.append(.init(id: owner, kind: .team, name: "Owners"))
            facts.append(fact(owner, .owns, project))
        }
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
}

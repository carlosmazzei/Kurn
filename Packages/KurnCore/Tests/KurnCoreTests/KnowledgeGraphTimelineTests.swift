import Foundation
import Testing
@testable import KurnCore

/// K4.3: which edges of a neighbourhood held on a day, and what changed between two.
struct KnowledgeGraphTimelineTests {
    private typealias Timeline = KnowledgeFixtureTimeline
    private typealias Point = KnowledgeStateComparison.Point

    private static func point(_ day: String, knownAt: Date = .distantFuture) throws -> Point {
        try #require(Point.endOfDay(Timeline.day(day), knownAt: knownAt))
    }

    private static func projectGraph(_ line: Timeline) throws -> KnowledgeGraph {
        let index = KnowledgeGraphIndex(pages: try KnowledgeWikiProjector.project(line.snapshot))
        let project = try #require(line.entities["e1"])
        return try #require(index.query(.init(rootID: project)))
    }

    @Test func theBlockerHoldsFromTheDayItWasStated() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let graph = try Self.projectGraph(line)
        let blocker = try #require(line.assertions["a6"])
        #expect(graph.edges.map(\.factID) == [blocker])
        let dayBefore = try Self.point("2026-10-19"), sameDay = try Self.point("2026-10-20"), later = try Self.point("2026-11-15")
        #expect(KnowledgeGraphTimeline.holdings(of: graph, at: dayBefore, claims: line.claims).isEmpty)
        // A day's precision cannot say whether it had started by the end of that day.
        #expect(KnowledgeGraphTimeline.holdings(of: graph, at: sameDay, claims: line.claims) == [blocker: .possible])
        #expect(KnowledgeGraphTimeline.holdings(of: graph, at: later, claims: line.claims) == [blocker: .definite])
        let september = try Self.point("2026-09-30")
        let changes = KnowledgeGraphTimeline.compare(graph, from: september, to: later, claims: line.claims)
        #expect(changes == [blocker: .init(factID: blocker, change: .started, before: nil, after: .definite)])
    }

    @Test func aLateImportIsNotKnownBeforeItArrived() throws {
        // Said on Oct 20, imported on Nov 14: as known on Nov 1, the blocker did not hold on Oct 31.
        let line = try Timeline.load("pt-provisioning-timeline")
        let graph = try Self.projectGraph(line)
        let blocker = try #require(line.assertions["a6"])
        let thenKnown = try Self.point("2026-10-31", knownAt: Timeline.date("2026-11-01"))
        #expect(KnowledgeGraphTimeline.holdings(of: graph, at: thenKnown, claims: line.claims).isEmpty)
        let nowKnown = try Self.point("2026-10-31", knownAt: Timeline.date("2026-11-15"))
        let changes = KnowledgeGraphTimeline.compare(graph, from: thenKnown, to: nowKnown, claims: line.claims)
        #expect(changes[blocker]?.change == .started)
    }

    @Test func endedKeptAndOrderIndependent() throws {
        let meeting = UUID(), root = UUID(), old = UUID(), steady = UUID()
        func fact(_ object: UUID, from: String, to: String? = nil) -> KnowledgeWikiSnapshot.Fact {
            .init(id: UUID(), subjectID: root, predicate: .dependsOn, objectID: object,
                  qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                    confidence: .medium, review: .machineExtracted, validFrom: Timeline.day(from),
                                    validTo: to.map(Timeline.day)),
                  source: .init(meetingID: meeting, recordedAt: Timeline.date("2026-01-01"), evidence: [
                      .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                            attributedSpeaker: "Speaker 1"),
                  ]))
        }
        let ended = fact(old, from: "2026-02-01", to: "2026-03-01"), kept = fact(steady, from: "2026-02-01")
        let pages = try KnowledgeWikiProjector.project(.init(revision: 1, entities: [
            .init(id: root, kind: .project, name: "Root"), .init(id: old, kind: .project, name: "Old"),
            .init(id: steady, kind: .project, name: "Steady"),
        ], facts: [ended, kept]))
        let graph = try #require(KnowledgeGraphIndex(pages: pages).query(.init(rootID: root)))
        let claims = KnowledgeStateComparison.claims(from: pages)
        let from = try Self.point("2026-02-15"), to = try Self.point("2026-04-15")
        let changes = KnowledgeGraphTimeline.compare(graph, from: from, to: to, claims: claims)
        #expect(changes[ended.id]?.change == .ended && changes[ended.id]?.after == nil)
        #expect(changes[kept.id]?.change == .kept && changes[kept.id]?.before == .definite)
        #expect(KnowledgeGraphTimeline.compare(graph, from: from, to: to, claims: claims.reversed()) == changes)
        // Before either started, nothing held at either point.
        let december = try Self.point("2025-12-01"), january = try Self.point("2026-01-15")
        #expect(KnowledgeGraphTimeline.compare(graph, from: december, to: january, claims: claims).isEmpty)
        let empty = KnowledgeGraph(query: .init(rootID: root, depth: 0), nodes: [], edges: [], isTruncated: false, frontier: [],
                                   supersessionCycles: [])
        #expect(KnowledgeGraphTimeline.holdings(of: empty, at: to, claims: claims).isEmpty)
    }

    @Test func anEquivalentClaimDoesNotLendItsCertainty() throws {
        // Two meetings say the root depends on the vendor; on Feb 15 the one
        // stated for January has started for certain, the one stated for
        // February only possibly. Each edge keeps its own certainty.
        let meeting = UUID(), other = UUID(), root = UUID(), vendor = UUID()
        func fact(_ month: String, meeting: UUID) -> KnowledgeWikiSnapshot.Fact {
            .init(id: UUID(), subjectID: root, predicate: .dependsOn, objectID: vendor,
                  qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                    confidence: .medium, review: .machineExtracted,
                                    validFrom: KnowledgeTemporalValue(text: month, precision: .month)),
                  source: .init(meetingID: meeting, recordedAt: Timeline.date("2026-01-01"), evidence: [
                      .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                            attributedSpeaker: "Speaker 1"),
                  ]))
        }
        let january = fact("2026-01", meeting: meeting), february = fact("2026-02", meeting: other)
        let pages = try KnowledgeWikiProjector.project(.init(revision: 1, entities: [
            .init(id: root, kind: .project, name: "Root"), .init(id: vendor, kind: .organization, name: "Vendor"),
        ], facts: [january, february]))
        let graph = try #require(KnowledgeGraphIndex(pages: pages).query(.init(rootID: root)))
        let mid = try Self.point("2026-02-15")
        let held = KnowledgeGraphTimeline.holdings(of: graph, at: mid, claims: KnowledgeStateComparison.claims(from: pages))
        #expect(held == [january.id: .definite, february.id: .possible])
    }
}

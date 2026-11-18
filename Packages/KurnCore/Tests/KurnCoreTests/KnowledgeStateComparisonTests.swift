import Foundation
import Testing
@testable import KurnCore

/// K3.4: comparing an entity's state at two moments, on either clock.
struct KnowledgeStateComparisonTests {
    private typealias Timeline = KnowledgeFixtureTimeline
    private typealias Comparison = KnowledgeStateComparison

    private static func point(_ day: String, knownAt: Date = .distantFuture) throws -> Comparison.Point {
        try #require(Comparison.Point.endOfDay(Timeline.day(day), knownAt: knownAt))
    }

    @Test func theProvisioningDecisionWasRevisedAndSupersededBetweenSeptemberAndNovember() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let decision = try #require(line.entities["e2"])
        let result = Comparison.compare(entityID: decision, earlier: try Self.point("2026-09-30"),
                                        later: try Self.point("2026-11-15"), claims: line.claims)
        #expect(result.changes.map(\.kind) == [.changed, .started])
        let status = try #require(result.changes.first)
        #expect(status.predicate == .hasStatus && status.direction == .outgoing)
        #expect(status.before?.value == .enumeration("approved") && status.after?.value == .enumeration("revised"))
        #expect(status.before?.certainty == .definite && status.after?.certainty == .definite)
        let superseded = try #require(result.changes.last)
        #expect(superseded.predicate == .supersedes && superseded.direction == .incoming)
        #expect(superseded.after?.otherEntityID == line.entities["e5"])
        #expect(result.hasDifferences)
    }

    @Test func theProjectGainedAStatusAndABlockerWhileItsMetricAndDueDateHeld() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let project = try #require(line.entities["e1"])
        let result = Comparison.compare(entityID: project, earlier: try Self.point("2026-09-30"),
                                        later: try Self.point("2026-11-15"), claims: line.claims)
        #expect(result.changes.map(\.kind) == [.started, .started, .unchanged, .unchanged])
        #expect(Set(result.changes.filter { $0.kind == .started }.map(\.predicate)) == [.blocks, .hasStatus])
        #expect(Set(result.changes.filter { $0.kind == .unchanged }.map(\.predicate)) == [.dueOn, .reportsMetric])
        #expect(result.changes.allSatisfy { !$0.certaintyChanged })
    }

    @Test func aLateImportChangesWhatWasKnownNotWhatHeld() throws {
        // The blocker was said on Oct 20 but imported on Nov 14: as of Nov 1
        // the store did not know it, even about Oct 31.
        let line = try Timeline.load("pt-provisioning-timeline")
        let project = try #require(line.entities["e1"])
        let result = Comparison.compare(entityID: project, earlier: try Self.point("2026-10-31", knownAt: Timeline.date("2026-11-01")),
                                        later: try Self.point("2026-10-31", knownAt: Timeline.date("2026-11-15")), claims: line.claims)
        let differences = result.changes.filter { $0.kind != .unchanged }
        #expect(differences.map(\.kind) == [.started])
        #expect(differences.first?.predicate == .blocks && differences.first?.direction == .incoming)
        #expect(differences.first?.after?.claimIDs == [line.assertions["a6"]].compactMap { $0 })
    }

    @Test func theResultDoesNotDependOnClaimOrder() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let project = try #require(line.entities["e1"])
        let earlier = try Self.point("2026-09-30"), later = try Self.point("2026-11-15")
        let forward = Comparison.compare(entityID: project, earlier: earlier, later: later, claims: line.claims)
        let backward = Comparison.compare(entityID: project, earlier: earlier, later: later, claims: line.claims.reversed())
        #expect(forward == backward)
    }

    // MARK: - Synthetic

    private static let subject = UUID(), other = UUID()

    private static func claim(_ predicate: KnowledgePredicate, value: KnowledgeTypedValue? = nil, object: UUID? = nil,
                              from: KnowledgeTemporalValue?, to: KnowledgeTemporalValue? = nil,
                              polarity: KnowledgePolarity = .positive) -> KnowledgeTemporalClaim {
        KnowledgeTemporalClaim(id: UUID(), subjectID: subject, predicate: predicate, objectID: object, value: value,
                               polarity: polarity, modality: .reported, validFrom: from, validTo: to,
                               recordedAt: Timeline.date("2026-01-01"))
    }

    @Test func aStatementThatStopsHoldingEndsAndANegationIsAChange() throws {
        let owner = Self.claim(.dependsOn, object: Self.other, from: Timeline.day("2026-03-01"), to: Timeline.day("2026-05-01"))
        let blocks = Self.claim(.blocks, object: Self.other, from: Timeline.day("2026-03-01"))
        let unblocked = Self.claim(.blocks, object: Self.other, from: Timeline.day("2026-06-01"), polarity: .negative)
        let result = Comparison.compare(entityID: Self.subject, earlier: try Self.point("2026-04-01"),
                                        later: try Self.point("2026-07-01"), claims: [owner, blocks, unblocked])
        #expect(result.changes.map(\.kind) == [.changed, .ended])
        #expect(result.changes[0].before?.polarity == .positive && result.changes[0].after?.polarity == .negative)
        #expect(result.changes[1].before?.claimIDs == [owner.id])
    }

    @Test func conflictingValuesAreNotPairedIntoAChange() throws {
        let first = Self.claim(.hasStatus, value: .enumeration("open"), from: Timeline.day("2026-03-01"))
        let second = Self.claim(.hasStatus, value: .enumeration("blocked"), from: Timeline.day("2026-03-01"))
        let settled = Self.claim(.hasStatus, value: .enumeration("ready"), from: Timeline.day("2026-05-01"))
        let result = Comparison.compare(entityID: Self.subject, earlier: try Self.point("2026-04-01"),
                                        later: try Self.point("2026-06-01"), claims: [first, second, settled])
        #expect(result.changes.map(\.kind) == [.started, .ended, .ended])
        #expect(result.earlier.conflicts.count == 1 && result.later.conflicts.isEmpty)
    }

    @Test func aStatementGrowsCertainWhenItsPeriodHasPassed() throws {
        let month = try #require(KnowledgeTemporalValue(text: "2026-03", precision: .month))
        let status = Self.claim(.hasStatus, value: .enumeration("open"), from: month)
        let result = Comparison.compare(entityID: Self.subject, earlier: try Self.point("2026-03-15"),
                                        later: try Self.point("2026-04-15"), claims: [status])
        #expect(result.changes.map(\.kind) == [.unchanged])
        #expect(result.changes[0].certaintyChanged && result.hasDifferences)
        let same = Comparison.compare(entityID: Self.subject, earlier: try Self.point("2026-04-15"),
                                      later: try Self.point("2026-05-15"), claims: [status])
        #expect(!same.hasDifferences)
    }

    @Test func pointsAreTheLastSecondOfAStatedDay() throws {
        let point = try Self.point("2026-03-15")
        #expect(point.validAt == Timeline.date("2026-03-15T23:59:59Z"))
        #expect(Comparison.Point.endOfDay(Timeline.day("2026-03-15"))?.knownAt == point.validAt)
        let month = try #require(KnowledgeTemporalValue(text: "2026-03", precision: .month))
        #expect(Comparison.Point.endOfDay(month) == nil)
    }

    @Test func claimsFromPagesSpeakOfTheIdentityAMergeLeadsTo() throws {
        let kept = UUID(), merged = UUID(), team = UUID()
        let fact = KnowledgeWikiSnapshot.Fact(
            id: UUID(), subjectID: merged, predicate: .dependsOn, objectID: team,
            qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                              confidence: .medium, review: .machineExtracted, validFrom: Timeline.day("2026-03-01")),
            source: .init(meetingID: UUID(), recordedAt: Timeline.date("2026-03-02"), evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                      attributedSpeaker: "Speaker 1"),
            ]))
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: [
            .init(id: kept, kind: .project, name: "Portal"), .init(id: merged, kind: .project, name: "Portal v2", targetID: kept),
            .init(id: team, kind: .team, name: "Platform"),
        ], facts: [fact])
        let claims = Comparison.claims(from: try KnowledgeWikiProjector.project(snapshot))
        #expect(claims.count == 1)
        #expect(claims.first?.subjectID == kept && claims.first?.objectID == team)
        #expect(claims.first?.recordedAt == fact.source.recordedAt)
    }
}

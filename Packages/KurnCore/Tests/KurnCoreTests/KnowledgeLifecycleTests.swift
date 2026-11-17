import Foundation
import Testing
@testable import KurnCore

/// K3.2: decision, action and risk lifecycles projected from stated status
/// changes, exact on the synthetic fixtures.
struct KnowledgeLifecycleTests {
    private typealias Timeline = KnowledgeFixtureTimeline
    private static func date(_ text: String) -> Date { Timeline.date(text) }
    private static func day(_ text: String) -> KnowledgeTemporalValue { Timeline.day(text) }
    private static let later = date("2026-12-31")

    private func status(_ status: String, on stated: KnowledgeTemporalValue?, modality: KnowledgeModality = .reported,
                        polarity: KnowledgePolarity = .positive, of subject: UUID) -> KnowledgeTemporalClaim {
        KnowledgeTemporalClaim(id: UUID(), subjectID: subject, predicate: .hasStatus, value: .enumeration(status),
                               polarity: polarity, modality: modality, validFrom: stated, recordedAt: Self.date("2026-01-01"))
    }

    private static func month(_ text: String) throws -> KnowledgeTemporalValue {
        try #require(KnowledgeTemporalValue(text: text, precision: .month))
    }

    @Test func aDecisionIsProposedApprovedRevisedAndSupersededByAnotherInitiative() throws {
        let line = try Timeline.load("pt-provisioning-timeline")
        let thread = try #require(line.entities["e2"])
        let projection = KnowledgeLifecycle.decision.project(entityID: thread, knownAt: Self.later, claims: line.claims)
        #expect(projection.transitions.map(\.status) == [.proposed, .approved, .revised, .superseded])
        #expect(projection.transitions.map(\.from) == [nil, .proposed, .approved, .revised])
        #expect(projection.transitions.allSatisfy { $0.orderBasis == .statedTime })
        let superseding = try #require(line.assertions["a8"])
        #expect(projection.transitions.last?.claimIDs == [superseding])
        #expect(projection.anomalies.isEmpty && projection.setAside.isEmpty)
        #expect(projection.state(at: Self.date("2026-09-15")) == .init(status: .proposed, certainty: .definite, transitionIndex: 0))
        #expect(projection.state(at: Self.date("2026-09-25"))?.certainty == .possible)
        #expect(projection.state(at: Self.date("2026-11-15")) == .init(status: .superseded, certainty: .definite, transitionIndex: 3))
        #expect(projection.state(at: Self.date("2026-09-01")) == nil)
        // Known before the superseding meeting was imported, it is still revised.
        let earlier = KnowledgeLifecycle.decision.project(entityID: thread, knownAt: Self.date("2026-11-10T13:00:00Z"),
                                                          claims: line.claims)
        #expect(earlier.state(at: Self.date("2026-11-15"))?.status == .revised)
        // The project itself has no lifecycle; the risk has one step.
        #expect(KnowledgeLifecycle(entityKind: .project) == nil)
        let risk = try #require(line.entities["e3"])
        #expect(KnowledgeLifecycle.risk.project(entityID: risk, knownAt: Self.later, claims: line.claims)
            .transitions.map(\.status) == [.identified])
    }

    @Test func aReopeningOrdersACompletionStatedOnlyByMonth() throws {
        let line = try Timeline.load("en-platform-review")
        let runbook = try #require(line.entities["e6"])
        let projection = KnowledgeLifecycle.action.project(entityID: runbook, knownAt: Self.later, claims: line.claims)
        #expect(projection.transitions.map(\.status) == [.completed, .reopened])
        #expect(projection.transitions.map(\.orderBasis) == [.lifecycle, .lifecycle])
        #expect(projection.anomalies.isEmpty)
        // November covers the 12th, but the reopening bounds the completion.
        #expect(projection.state(at: Self.date("2026-11-05")) == .init(status: .completed, certainty: .possible, transitionIndex: 0))
        #expect(projection.state(at: Self.date("2026-11-20")) == .init(status: .reopened, certainty: .definite, transitionIndex: 1))
    }

    @Test func theMachinePutsACommitmentBeforeACompletionStatedByMonth() throws {
        let item = UUID()
        let claims = [status("completed", on: try Self.month("2026-11"), of: item),
                      status("committed", on: Self.day("2026-11-03"), of: item)]
        let projection = KnowledgeLifecycle.action.project(entityID: item, knownAt: Self.later, claims: claims)
        #expect(projection.transitions.map(\.status) == [.committed, .completed])
        #expect(projection.transitions.map(\.orderBasis) == [.lifecycle, .lifecycle])
        #expect(projection.anomalies.isEmpty)
        #expect(projection.state(at: Self.date("2026-12-02"))?.status == .completed)
    }

    @Test func anOrderNeitherDatesNorMachineDecideIsAmbiguous() throws {
        let decision = UUID()
        let deferred = status("deferred", on: try Self.month("2026-10"), of: decision)
        let proposed = status("proposed", on: Self.day("2026-10-10"), of: decision)
        let projection = KnowledgeLifecycle.decision.project(entityID: decision, knownAt: Self.later, claims: [proposed, deferred])
        #expect(projection.transitions.last?.orderBasis == .ambiguous)
        #expect(projection.anomalies.map(\.code) == [.ambiguousOrder])
        let ambiguity = try #require(projection.anomalies.first)
        #expect(Set(ambiguity.claimIDs) == [deferred.id, proposed.id])
        #expect(projection.state(at: Self.date("2026-12-01"))?.certainty == .possible)
    }

    @Test func aTransitionTheMachineForbidsIsKeptAndReported() {
        let decision = UUID()
        let approved = status("approved", on: Self.day("2026-09-01"), of: decision)
        let proposed = status("proposed", on: Self.day("2026-10-01"), of: decision)
        let rogue = status("ready", on: Self.day("2026-10-05"), of: decision)
        let projection = KnowledgeLifecycle.decision.project(entityID: decision, knownAt: Self.later,
                                                             claims: [proposed, approved, rogue])
        #expect(projection.transitions.map(\.status) == [.approved, .proposed])
        #expect(projection.anomalies.map(\.code) == [.invalidTransition, .outOfVocabulary])
        #expect(projection.anomalies.last?.claimIDs == [rogue.id])
        #expect(projection.state(at: Self.date("2026-10-20"))?.status == .proposed)
    }

    @Test func tentativeNegatedAndUndatedClaimsAreSetAside() {
        let decision = UUID()
        let proposal = status("proposed", on: Self.day("2026-09-01"), modality: .proposed, of: decision)
        let wish = status("approved", on: Self.day("2026-09-05"), modality: .proposed, of: decision)
        let guess = status("approved", on: Self.day("2026-09-06"), modality: .hypothetical, of: decision)
        let denial = status("rejected", on: Self.day("2026-09-07"), polarity: .negative, of: decision)
        let undated = status("approved", on: nil, of: decision)
        let projection = KnowledgeLifecycle.decision.project(entityID: decision, knownAt: Self.later,
                                                             claims: [undated, denial, guess, wish, proposal])
        #expect(projection.transitions.map(\.status) == [.proposed])
        #expect(projection.setAside.map(\.reason) == [.negated, .tentative, .tentative, .undated])
        #expect(Set(projection.setAside.map(\.claimID)) == [wish.id, guess.id, denial.id, undated.id])
    }

    @Test func restatementsJoinOneTransitionAndInputOrderIsIrrelevant() {
        let item = UUID()
        let first = status("committed", on: Self.day("2026-10-01"), of: item)
        let again = status("committed", on: Self.day("2026-10-01"), modality: .agreed, of: item)
        let later = status("committed", on: Self.day("2026-10-09"), of: item)
        let done = status("completed", on: Self.day("2026-10-20"), of: item)
        let claims = [first, again, later, done]
        let projection = KnowledgeLifecycle.action.project(entityID: item, knownAt: Self.later, claims: claims)
        #expect(projection.transitions.map(\.status) == [.committed, .completed])
        #expect(Set(projection.transitions[0].claimIDs) == [first.id, again.id, later.id])
        #expect(projection.transitions[0].stated == Self.day("2026-10-01"))
        for _ in 0..<8 {
            #expect(KnowledgeLifecycle.action.project(entityID: item, knownAt: Self.later, claims: claims.shuffled()) == projection)
        }
    }

    @Test func aWholeGroupOfOverlappingChangesIsOrderedByTheMachine() throws {
        let item = UUID()
        let november = try Self.month("2026-11")
        let claims = [status("completed", on: november, of: item), status("inProgress", on: november, of: item),
                      status("committed", on: Self.day("2026-11-03"), of: item)]
        let projection = KnowledgeLifecycle.action.project(entityID: item, knownAt: Self.later, claims: claims)
        #expect(projection.transitions.map(\.status) == [.committed, .inProgress, .completed])
        #expect(projection.anomalies.isEmpty)
        #expect(projection.state(at: Self.date("2026-12-02")) == .init(status: .completed, certainty: .definite, transitionIndex: 2))
    }

    @Test func overlappingChangesNoOrderAllowsAreUnresolvedAndNeverDefinite() throws {
        let decision = UUID()
        let approved = status("approved", on: try Self.month("2026-10"), of: decision)
        let rejected = status("rejected", on: Self.day("2026-10-15"), of: decision)
        let projection = KnowledgeLifecycle.decision.project(entityID: decision, knownAt: Self.later, claims: [rejected, approved])
        #expect(projection.transitions.map(\.orderBasis) == [.unresolved, .unresolved])
        #expect(projection.anomalies.map(\.code) == [.invalidTransition, .unresolvedOrder])
        #expect(projection.state(at: Self.date("2026-11-02"))?.certainty == .possible)
    }

    @Test func overlappingRestatementsOfOneStatusAreNotAnOrderQuestion() throws {
        let decision = UUID()
        let approved = status("approved", on: Self.day("2026-09-10"), of: decision)
        let revisedInOctober = status("revised", on: try Self.month("2026-10"), of: decision)
        let revisedOnTheTenth = status("revised", on: Self.day("2026-10-10"), of: decision)
        let projection = KnowledgeLifecycle.decision.project(entityID: decision, knownAt: Self.later,
                                                             claims: [revisedOnTheTenth, revisedInOctober, approved])
        #expect(projection.transitions.map(\.status) == [.approved, .revised])
        #expect(Set(projection.transitions[1].claimIDs) == [revisedInOctober.id, revisedOnTheTenth.id])
        #expect(projection.transitions[1].stated == revisedInOctober.validFrom)
        #expect(projection.anomalies.isEmpty)
    }

    @Test func everyLifecycleStartsAndTransitionsOnlyThroughItsOwnStatuses() {
        #expect(KnowledgeLifecycle.action.allows(from: .completed, to: .reopened))
        #expect(!KnowledgeLifecycle.action.allows(from: nil, to: .reopened))
        #expect(!KnowledgeLifecycle.decision.allows(from: .superseded, to: .approved))
        #expect(KnowledgeLifecycle.risk.allows(from: .accepted, to: .reopened))
        #expect(KnowledgeLifecycle.risk.statuses == [.identified, .mitigated, .accepted, .closed, .reopened])
        #expect(!KnowledgeLifecycle.decision.statuses.contains(.completed))
        #expect(KnowledgeLifecycle(entityKind: .actionItem) == .action)
    }
}

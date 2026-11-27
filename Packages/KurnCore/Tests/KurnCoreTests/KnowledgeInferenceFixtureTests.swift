import Foundation
import Testing
@testable import KurnCore

/// K7.4 measured on the golden fixtures: what the derivations offer against what a reader would accept.
/// The numbers are recorded, not tuned: a change that moves them is a change to read, like the pipeline evaluation.
struct KnowledgeInferenceFixtureTests {
    private static let names = [
        "en-moved-deadline", "en-platform-review", "en-three-contexts", "pt-corrected-transcript", "pt-provisioning-timeline"
    ]

    private static func edges(of snapshot: KnowledgeWikiSnapshot) -> [KnowledgeGraph.Edge] {
        snapshot.facts.compactMap { fact in
            guard let target = fact.objectID else { return nil }
            return KnowledgeGraph.Edge(factID: fact.id, sourceID: fact.subjectID, targetID: target, predicate: fact.predicate,
                                       polarity: fact.qualifiers.polarity, modality: fact.qualifiers.modality, evidenceID: nil)
        }
    }

    @Test func noFixtureStatesAChainSoNothingIsDerivedFromThem() throws {
        // Every fixture states its blocks/supersedes claims directly and none chains two: a derived edge here
        // would be a false positive.
        for name in Self.names {
            let timeline = try KnowledgeFixtureTimeline.load(name)
            let result = KnowledgeInference.derive(from: Self.edges(of: timeline.snapshot))
            #expect(result.edges.isEmpty, "\(name)")
            #expect(result.cyclic.isEmpty, "\(name)")
        }
    }

    @Test func noFixtureOffersASameAsCandidateForItsMustNotMergePairs() throws {
        // Alex / Alex Moreno share one word, which is below the review floor: nothing is suggested, so a
        // reviewer is never invited to merge two people the fixture says are different.
        for name in Self.names {
            let timeline = try KnowledgeFixtureTimeline.load(name)
            let result = try KnowledgeInference.deriveSameAsCandidates(from: timeline.snapshot.entities, profile: .experimental)
            #expect(result.candidates.isEmpty, "\(name)")
        }
    }

    @Test func commitmentsAreRecallCompleteButOnlyAsPreciseAsTheirPairings() throws {
        // The moved-deadline fixture assigns the review to Maria, then to Lee, and moves its due date twice.
        // The one commitment true at the end is Lee → 2026-11-06 (a6 with a5). The derivation lists every
        // owner × date pairing and leaves the current one to the temporal reducer: recall 1, precision 1/6.
        let timeline = try KnowledgeFixtureTimeline.load("en-moved-deadline")
        let result = KnowledgeInference.deriveCommitments(from: timeline.snapshot.facts)
        #expect(!result.isTruncated)
        #expect(result.commitments.count == 6)
        let current = [try #require(timeline.assertions["a6"]), try #require(timeline.assertions["a5"])]
        let matching = result.commitments.filter { $0.premiseFactIDs == current }
        #expect(matching.count == 1)
        #expect(matching.first?.ownerID == timeline.entities["e4"])
        #expect(matching.first?.due == Self.dayValue("2026-11-06"))
        // A commitment needs both halves: no other fixture states an owner and a date for one action.
        for name in Self.names where name != "en-moved-deadline" {
            let other = try KnowledgeFixtureTimeline.load(name)
            #expect(KnowledgeInference.deriveCommitments(from: other.snapshot.facts).commitments.isEmpty, "\(name)")
        }
    }

    private static func dayValue(_ text: String) -> KnowledgeTemporalValue { KnowledgeFixtureTimeline.day(text) }
}

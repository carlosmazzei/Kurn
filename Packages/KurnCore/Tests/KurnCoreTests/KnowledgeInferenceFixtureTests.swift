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

    @Test func theOnlySameAsCandidateIsTheHomonymPairAndItStaysReviewOnly() throws {
        // "Alex" is a recorded alias of "Alex Moreno" (e4), and the fixture says the two must not merge (e3, e4).
        // The alias makes them a review suggestion (0.15 alias + 0.5 × 0.25 words = 0.275, above the 0.15
        // floor): a false positive of the suggestion list, kept because nothing is merged without a person.
        // No other fixture offers any pair.
        var offered: [String] = []
        for name in Self.names {
            let timeline = try KnowledgeFixtureTimeline.load(name)
            let result = try KnowledgeInference.deriveSameAsCandidates(from: timeline.snapshot.entities, profile: .experimental)
            #expect(!result.isTruncated, "\(name)")
            for candidate in result.candidates {
                #expect(candidate.requiresHumanReview, "\(name)")
                #expect(abs(candidate.score - 0.275) < 0.000_001, "\(name)")
                let pair: Set<UUID> = [candidate.firstID, candidate.secondID]
                var homonyms = Set<UUID>()
                if let first = timeline.entities["e3"], let second = timeline.entities["e4"] { homonyms = [first, second] }
                if name == "en-platform-review", pair == homonyms {
                    offered.append("\(name):e3+e4")
                } else {
                    offered.append("\(name):other")
                }
            }
        }
        #expect(offered == ["en-platform-review:e3+e4"])
    }

    @Test func commitmentsAreRecallCompleteButOnlyAsPreciseAsTheirPairings() throws {
        // The moved-deadline fixture assigns the review to Maria, then to Lee, and moves its due date twice.
        // The one commitment true at the end, by the fixture's own narration, is Lee → 2026-11-06 (a6 with a5).
        // The derivation lists every owner × date pairing: recall 1, precision 1/6. `deriveCurrentCommitments`
        // narrows them by stated start, with the reducer's rule extended to the owner.
        let timeline = try KnowledgeFixtureTimeline.load("en-moved-deadline")
        let result = KnowledgeInference.deriveCommitments(from: timeline.snapshot.facts)
        #expect(!result.isTruncated)
        #expect(result.commitments.count == 6)
        let current = [try #require(timeline.assertions["a6"]), try #require(timeline.assertions["a5"])]
        let matching = result.commitments.filter { $0.premiseFactIDs == current }
        #expect(matching.count == 1)
        #expect(matching.first?.ownerID == timeline.entities["e4"])
        #expect(matching.first?.due == Self.dayValue("2026-11-06"))
        // Narrowed by stated start (a later assignment or date replaces an earlier one), the same facts give
        // exactly that commitment: recall 1, precision 1.
        let narrowed = KnowledgeInference.deriveCurrentCommitments(from: timeline.snapshot.facts)
        #expect(narrowed.commitments.map(\.premiseFactIDs) == [current])
        // A commitment needs both halves: no other fixture states an owner and a date for one action.
        for name in Self.names where name != "en-moved-deadline" {
            let other = try KnowledgeFixtureTimeline.load(name)
            #expect(KnowledgeInference.deriveCommitments(from: other.snapshot.facts).commitments.isEmpty, "\(name)")
        }
    }

    private static func dayValue(_ text: String) -> KnowledgeTemporalValue { KnowledgeFixtureTimeline.day(text) }
}

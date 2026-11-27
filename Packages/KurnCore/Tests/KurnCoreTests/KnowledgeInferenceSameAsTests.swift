import Foundation
import Testing
@testable import KurnCore

/// K7.4: `same_as` candidates are review suggestions, never links.
struct KnowledgeInferenceSameAsTests {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    private static func entity(_ n: Int, _ name: String, kind: KnowledgeEntityKind = .project, aliases: [String] = [],
                               target: Int? = nil) -> KnowledgeWikiSnapshot.Entity {
        KnowledgeWikiSnapshot.Entity(id: id(n), kind: kind, name: name, aliases: aliases, targetID: target.map(id))
    }

    private static func derive(_ entities: [KnowledgeWikiSnapshot.Entity]) throws -> KnowledgeInference.SameAsResult {
        try KnowledgeInference.deriveSameAsCandidates(from: entities, profile: .experimental)
    }

    @Test func twoIdentitiesWithTheSameNameAreOneCandidatePair() throws {
        let result = try Self.derive([Self.entity(2, "Client Portal"), Self.entity(1, "client  portal")])
        #expect(result.candidates.count == 1)
        let pair = result.candidates.first
        #expect(pair?.firstID == Self.id(1) && pair?.secondID == Self.id(2))
        #expect(pair?.exactName == true && pair?.modality == .inferred && pair?.requiresHumanReview == true)
    }

    @Test func anAliasOrManySharedWordsIsEnoughButOneGenericWordIsNot() throws {
        let alias = try Self.derive([Self.entity(1, "Portal", aliases: ["Client Portal"]), Self.entity(2, "Client Portal")])
        #expect(alias.candidates.first?.aliasMatch == true)
        // Words alone need a similarity of at least 0.6 under the experimental profile (0.25 weight, 0.15 floor).
        let words = try Self.derive([Self.entity(1, "Client Portal Redesign Plan"), Self.entity(2, "Client Portal Redesign Plan v2")])
        #expect(words.candidates.count == 1)
        let fewWords = try Self.derive([Self.entity(1, "Client Portal Redesign"), Self.entity(2, "Client Portal Launch")])
        #expect(fewWords.candidates.isEmpty)
        let generic = try Self.derive([Self.entity(1, "Budget Review"), Self.entity(2, "Hiring Review")])
        #expect(generic.candidates.isEmpty)
    }

    @Test func differentKindsAndMergedIdentitiesNeverMatch() throws {
        let kinds = try Self.derive([Self.entity(1, "Maria", kind: .person), Self.entity(2, "Maria", kind: .project)])
        #expect(kinds.candidates.isEmpty)
        let merged = try Self.derive([Self.entity(1, "Client Portal"), Self.entity(2, "Client Portal", target: 1)])
        #expect(merged.candidates.isEmpty)
    }

    @Test func peopleAreCandidatesToo_butStillNeedAHumanDecision() throws {
        let result = try Self.derive([Self.entity(1, "Maria Santos", kind: .person), Self.entity(2, "Maria Santos", kind: .person)])
        #expect(result.candidates.first?.requiresHumanReview == true)
    }

    @Test func theBestScoreComesFirstAndTheOrderOfTheInputDoesNotMatter() throws {
        let entities = [
            Self.entity(1, "Client Portal"), Self.entity(2, "Client Portal"),
            Self.entity(3, "Client Portal Redesign"), Self.entity(4, "Client Portal Launch")
        ]
        let result = try Self.derive(entities)
        #expect(result.candidates.first?.exactName == true)
        let reversed = try Self.derive(Array(entities.reversed()))
        #expect(result == reversed)
    }

    @Test func aRepeatedIdentityCountsOnce() throws {
        let result = try Self.derive([Self.entity(1, "Client Portal"), Self.entity(1, "Client Portal"), Self.entity(2, "Client Portal")])
        #expect(result.candidates.count == 1)
    }

    @Test func aDenseSetIsMarkedTruncatedAtTheBound() throws {
        // 20 groups of 25 identities sharing one name: well over the bound.
        var entities: [KnowledgeWikiSnapshot.Entity] = []
        for group in 0..<20 {
            for member in 0..<25 { entities.append(Self.entity(group * 100 + member + 1, "Group \(group) Alpha Beta")) }
        }
        let result = try Self.derive(entities)
        #expect(result.isTruncated)
        #expect(result.candidates.count == KnowledgeInference.maximumEdges)
    }

    @Test func aProfileDecodedWithBadValuesThrowsInsteadOfBypassingValidation() throws {
        let json = Data(#"{"identifier":"x","exactNameWeight":0.6,"aliasWeight":0.15,"tokenWeight":0.25,"minimumScore":2,"maximumCandidates":5}"#.utf8)
        let bad = try JSONDecoder().decode(KnowledgeEntityResolutionProfile.self, from: json)
        #expect(throws: KnowledgeEntityResolutionError.self) {
            try KnowledgeInference.deriveSameAsCandidates(from: [], profile: bad)
        }
    }

    @Test func pairsTheReviewListCutsAreStillCountedAsTruncation() throws {
        // 15 groups of 8 identities with one name each: 15 × 28 = 420 eligible pairs, while a review list
        // keeps only five per identity. The derivation sees all 420, returns the best 400 and says it cut.
        var entities: [KnowledgeWikiSnapshot.Entity] = []
        for group in 0..<15 {
            for member in 0..<8 { entities.append(Self.entity(group * 10 + member + 1, "Team\(group) Roadmap Plan")) }
        }
        let result = try Self.derive(entities)
        #expect(result.isTruncated)
        #expect(result.candidates.count == KnowledgeInference.maximumEdges)
    }

    @Test func aRepeatedIdentityWithDifferentDataIsChosenByTheDataNotTheOrder() throws {
        let first = [Self.entity(1, "Alpha Beta"), Self.entity(1, "Client Portal"), Self.entity(2, "Client Portal")]
        let second = [Self.entity(2, "Client Portal"), Self.entity(1, "Client Portal"), Self.entity(1, "Alpha Beta")]
        #expect(try Self.derive(first) == Self.derive(second))
    }

    @Test func aRepeatedIdentityWithAnotherKindIsChosenByTheKindNotTheOrder() throws {
        let first = [Self.entity(1, "Alpha Beta", kind: .project), Self.entity(1, "Alpha Beta", kind: .person),
                     Self.entity(2, "Alpha Beta", kind: .project)]
        let second = [first[2], first[1], first[0]]
        let result = try Self.derive(first)
        #expect(result == (try Self.derive(second)))
        // "person" sorts before "project", so identity 1 is the person and no same-kind pair remains.
        #expect(result.candidates.isEmpty)
    }

    @Test func theScanStopsAtTheLimitAndSaysSoWithoutLosingTheBestOfWhatItSaw() throws {
        // 60 groups of 30 identities, each sharing one name: 60 × 435 = 26,100 eligible pairs, past the
        // 25,600 the scan will look at. Every pair scores the same, so the best 400 are the lowest IDs.
        var entities: [KnowledgeWikiSnapshot.Entity] = []
        for group in 0..<60 {
            for member in 0..<30 { entities.append(Self.entity(group * 100 + member + 1, "Team\(group) Roadmap Plan")) }
        }
        let result = try Self.derive(entities)
        #expect(result.isTruncated)
        #expect(result.candidates.count == KnowledgeInference.maximumEdges)
        let ids = result.candidates.map { $0.firstID.uuidString }
        #expect(ids == ids.sorted())
        #expect(try Self.derive(Array(entities.reversed())) == result)
    }
}

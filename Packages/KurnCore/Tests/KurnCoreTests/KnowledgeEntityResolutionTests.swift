import Foundation
import Testing
@testable import KurnCore

struct KnowledgeEntityResolutionTests {
    private func id(_ suffix: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))! }

    @Test func namesNormalizeConservativelyAndScoresExplainRanking() throws {
        let query = KnowledgeEntityResolutionValue(id: id(1), kind: .project, name: "  Éxample   Portal ", aliases: ["EP"])
        let exact = KnowledgeEntityResolutionValue(id: id(2), kind: .project, name: "example portal")
        let alias = KnowledgeEntityResolutionValue(id: id(3), kind: .project, name: "Other name", aliases: ["EP"])
        let unrelated = KnowledgeEntityResolutionValue(id: id(4), kind: .project, name: "Example unrelated")
        let wrongKind = KnowledgeEntityResolutionValue(id: id(5), kind: .person, name: "Example Portal")
        let matches = try KnowledgeEntityResolver.rank(query, candidates: [unrelated, alias, wrongKind, exact], profile: .experimental)
        #expect(matches.map(\.entityID) == [exact.id, alias.id])
        #expect(matches.first?.exactName == true)
        #expect(matches.first?.tokenSimilarity == 1)
        #expect(matches.last?.aliasMatch == true)
        #expect(matches.allSatisfy { $0.requiresHumanReview })
        #expect(KnowledgeEntityResolver.normalizedName("Portal-A") != KnowledgeEntityResolver.normalizedName("Portal A"))
    }

    @Test func identicalPeopleRemainSeparateReviewCandidatesWithStableTieOrder() throws {
        let query = KnowledgeEntityResolutionValue(id: id(1), kind: .person, name: "Example Alex")
        let people = [3, 2].map { KnowledgeEntityResolutionValue(id: id($0), kind: .person, name: "Example Alex") }
        let matches = try KnowledgeEntityResolver.rank(query, candidates: people + [query], profile: .experimental)
        #expect(matches.map(\.entityID) == [id(2), id(3)])
        #expect(matches.allSatisfy { $0.requiresHumanReview })
        let strict = try KnowledgeEntityResolutionProfile(identifier: "test-v1", exactNameWeight: 1, aliasWeight: 0,
            tokenWeight: 0, minimumScore: 1, maximumCandidates: 1)
        #expect(try KnowledgeEntityResolver.rank(query, candidates: people, profile: strict).map(\.entityID) == [id(2)])
    }

    @Test func profilesRejectInvalidNumbersAndDecodedValuesCannotBypassValidation() throws {
        for weight in [Double.nan, .infinity, -1, 2] {
            #expect(throws: KnowledgeEntityResolutionError.invalidProfile) {
                try KnowledgeEntityResolutionProfile(identifier: "test", exactNameWeight: weight, aliasWeight: 0,
                    tokenWeight: 0, minimumScore: 0, maximumCandidates: 1)
            }
        }
        let invalid = Data(#"{"identifier":"test","exactNameWeight":1,"aliasWeight":1,"tokenWeight":1,"minimumScore":0,"maximumCandidates":1}"#.utf8)
        let profile = try JSONDecoder().decode(KnowledgeEntityResolutionProfile.self, from: invalid)
        let value = KnowledgeEntityResolutionValue(id: id(1), kind: .topic, name: "Example")
        #expect(throws: KnowledgeEntityResolutionError.invalidProfile) { try KnowledgeEntityResolver.rank(value, candidates: [], profile: profile) }
        #expect(throws: KnowledgeEntityResolutionError.duplicateEntity) {
            try KnowledgeEntityResolver.rank(value, candidates: [value, value], profile: .experimental)
        }
        #expect(try KnowledgeEntityResolver.rank(.init(id: id(9), kind: .topic, name: "  "), candidates: [], profile: .experimental).isEmpty)
    }

    @Test func redirectTraversalPreservesEdgesAndRejectsCyclesMissingNodesAndKindChanges() throws {
        let first = KnowledgeEntityRedirect(id: id(1), kind: .topic, targetID: id(2))
        let second = KnowledgeEntityRedirect(id: id(2), kind: .topic, targetID: id(3))
        let third = KnowledgeEntityRedirect(id: id(3), kind: .topic)
        let nodes = [first.id: first, second.id: second, third.id: third]
        #expect(try KnowledgeEntityRedirectGraph.resolve(first.id, nodes: nodes) == third.id)
        #expect(nodes[first.id]?.targetID == second.id)
        #expect(throws: KnowledgeEntityResolutionError.redirectLimit) { try KnowledgeEntityRedirectGraph.resolve(first.id, nodes: nodes, maximumDepth: 2) }
        #expect(throws: KnowledgeEntityResolutionError.missingEntity) { try KnowledgeEntityRedirectGraph.resolve(first.id, nodes: [first.id: first]) }
        let cycle = KnowledgeEntityRedirect(id: third.id, kind: .topic, targetID: first.id)
        #expect(throws: KnowledgeEntityResolutionError.redirectCycle) {
            try KnowledgeEntityRedirectGraph.resolve(first.id, nodes: [first.id: first, second.id: second, third.id: cycle])
        }
        let wrongKind = KnowledgeEntityRedirect(id: second.id, kind: .person)
        #expect(throws: KnowledgeEntityResolutionError.kindMismatch) { try KnowledgeEntityRedirectGraph.resolve(first.id, nodes: [first.id: first, second.id: wrongKind]) }
    }
}

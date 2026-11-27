import Foundation
import Testing
@testable import KurnCore

/// K7.4: derived edges carry their premises and never come from weak claims.
struct KnowledgeInferenceTests {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    private static func edge(_ fact: Int, _ from: Int, _ predicate: KnowledgePredicate, _ to: Int,
                             polarity: KnowledgePolarity = .positive,
                             modality: KnowledgeModality = .agreed) -> KnowledgeGraph.Edge {
        KnowledgeGraph.Edge(factID: id(fact), sourceID: id(from), targetID: id(to), predicate: predicate,
                            polarity: polarity, modality: modality, evidenceID: nil)
    }

    @Test func blocksChainsAndDependsOnReadsTheSameWay() {
        // 1 blocks 2; 3 dependsOn 2 means 2 blocks 3; so 1 precedes 3 through 2.
        let result = KnowledgeInference.derive(from: [Self.edge(101, 1, .blocks, 2), Self.edge(102, 3, .dependsOn, 2)])
        #expect(result.edges.count == 1)
        let derived = result.edges.first
        #expect(derived?.sourceID == Self.id(1) && derived?.targetID == Self.id(3))
        #expect(derived?.predicate == .blocks && derived?.modality == .inferred)
        #expect(derived?.premiseFactIDs == [Self.id(101), Self.id(102)])
    }

    @Test func aStatedClaimBetweenThePairLeavesNothingToDerive() {
        let edges = [Self.edge(101, 1, .blocks, 2), Self.edge(102, 2, .blocks, 3), Self.edge(103, 1, .blocks, 3)]
        #expect(KnowledgeInference.derive(from: edges).edges.isEmpty)
    }

    @Test func weakClaimsAreNotPremises() {
        let weak: [KnowledgeGraph.Edge] = [
            Self.edge(102, 2, .blocks, 3, polarity: .negative),
            Self.edge(102, 2, .blocks, 3, modality: .proposed),
            Self.edge(102, 2, .blocks, 3, modality: .inferred)
        ]
        for edge in weak {
            #expect(KnowledgeInference.derive(from: [Self.edge(101, 1, .blocks, 2), edge]).edges.isEmpty)
        }
    }

    @Test func supersessionChainsAndRulesDoNotMix() {
        let result = KnowledgeInference.derive(from: [
            Self.edge(101, 1, .supersedes, 2), Self.edge(102, 2, .supersedes, 3), Self.edge(103, 3, .blocks, 4)
        ])
        #expect(result.edges.map(\.rule) == [.supersessionChain])
        #expect(result.edges.first?.predicate == .supersedes)
    }

    @Test func aCycleDerivesNothingThroughItsMembers() {
        let result = KnowledgeInference.derive(from: [
            Self.edge(101, 1, .blocks, 2), Self.edge(102, 2, .blocks, 3), Self.edge(103, 3, .blocks, 1),
            Self.edge(104, 3, .blocks, 4)
        ])
        #expect(result.edges.isEmpty)
        #expect(result.cyclic[.transitiveBlocks] == [Self.id(1), Self.id(2), Self.id(3)])
    }

    @Test func chainsAreBoundedByHopsAndUseTheShortestPremises() {
        let line = (1...6).map { Self.edge(100 + $0, $0, .blocks, $0 + 1) }
        let three = KnowledgeInference.derive(from: line, hops: 3)
        #expect(!three.edges.contains { $0.sourceID == Self.id(1) && $0.targetID == Self.id(5) })
        #expect(three.edges.contains { $0.sourceID == Self.id(1) && $0.targetID == Self.id(4) })
        // A shortcut wins over a longer way round.
        let shortcut = KnowledgeInference.derive(from: [
            Self.edge(101, 1, .blocks, 2), Self.edge(102, 2, .blocks, 3), Self.edge(103, 3, .blocks, 4),
            Self.edge(104, 1, .blocks, 5), Self.edge(105, 5, .blocks, 4)
        ])
        let viaFive = shortcut.edges.first { $0.sourceID == Self.id(1) && $0.targetID == Self.id(4) }
        #expect(viaFive?.premiseFactIDs == [Self.id(104), Self.id(105)])
    }

    @Test func theOutputIsTheSameInAnyInputOrder() {
        let edges = [Self.edge(101, 1, .blocks, 2), Self.edge(102, 2, .blocks, 3), Self.edge(103, 3, .blocks, 4),
                     Self.edge(104, 1, .supersedes, 5), Self.edge(105, 5, .supersedes, 6)]
        #expect(KnowledgeInference.derive(from: edges) == KnowledgeInference.derive(from: edges.reversed()))
    }

    @Test func aDenseGraphIsMarkedTruncatedNotSilentlyCut() {
        // 900 two-step pairs, more than the output bound.
        var edges: [KnowledgeGraph.Edge] = []
        var fact = 1
        for a in 0..<30 {
            for b in 0..<30 {
                edges.append(Self.edge(fact, 1000 + a, .blocks, 2000 + b)); fact += 1
                edges.append(Self.edge(fact, 2000 + b, .blocks, 3000 + a * 30 + b)); fact += 1
            }
        }
        let result = KnowledgeInference.derive(from: edges)
        #expect(result.isTruncated)
        #expect(result.edges.count == KnowledgeInference.maximumEdges)
    }
}

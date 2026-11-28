import Foundation
import Testing
@testable import KurnCore

/// The derivations over the pages of one read, kept to what touches the shown identities.
struct KnowledgeInferencePagesTests {
    private struct Builder {
        var entities: [KnowledgeWikiSnapshot.Entity] = []
        var facts: [KnowledgeWikiSnapshot.Fact] = []

        mutating func entity(_ name: String, kind: KnowledgeEntityKind = .project) -> UUID {
            let id = UUID()
            entities.append(.init(id: id, kind: kind, name: name))
            return id
        }

        @discardableResult
        mutating func fact(_ subject: UUID, _ predicate: KnowledgePredicate, _ object: UUID) -> UUID {
            let id = UUID()
            facts.append(.init(
                id: id, subjectID: subject, predicate: predicate, objectID: object,
                qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport,
                                  authority: .attributed, confidence: .medium, review: .machineExtracted),
                source: .init(meetingID: UUID(), recordedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ])))
            return id
        }

        func pages() throws -> [KnowledgeWikiPage] {
            try KnowledgeWikiProjector.project(.init(revision: 1, entities: entities, facts: facts))
        }
    }

    @Test func aChainDerivesAnEdgeOnlyForTheIdentitiesAskedAbout() throws {
        var graph = Builder()
        let a = graph.entity("Alpha"), b = graph.entity("Beta"), c = graph.entity("Gamma")
        let x = graph.entity("Xi"), y = graph.entity("Psi"), z = graph.entity("Omega")
        let first = graph.fact(a, .blocks, b), second = graph.fact(b, .blocks, c)
        graph.fact(x, .blocks, y)
        graph.fact(y, .blocks, z)
        let pages = try graph.pages()
        let near = try KnowledgeInference.suggestions(from: pages, touching: [a])
        #expect(near.edges.map(\.sourceID) == [a] && near.edges.map(\.targetID) == [c])
        #expect(near.edges.first?.premiseFactIDs == [first, second])
        #expect(!near.isTruncated)
        let none = try KnowledgeInference.suggestions(from: pages, touching: [UUID()])
        #expect(none.edges.isEmpty && none.commitments.isEmpty && none.sameAs.isEmpty)
        let both = try KnowledgeInference.suggestions(from: pages, touching: [a, x])
        #expect(both.edges.count == 2)
    }

    @Test func aSharedNameIsASameAsCandidateForReviewAndPageOrderChangesNothing() throws {
        var graph = Builder()
        let first = graph.entity("Alex Moreno", kind: .person), second = graph.entity("Alex Moreno", kind: .person)
        let other = graph.entity("Billing")
        graph.fact(first, .relatesTo, other)
        graph.fact(second, .relatesTo, other)
        let pages = try graph.pages()
        let result = try KnowledgeInference.suggestions(from: pages, touching: [first])
        #expect(result.sameAs.count == 1)
        #expect(Set([result.sameAs[0].firstID, result.sameAs[0].secondID]) == [first, second])
        #expect(result.sameAs[0].requiresHumanReview)
        #expect(try KnowledgeInference.suggestions(from: Array(pages.reversed()), touching: [first]) == result)
    }
}

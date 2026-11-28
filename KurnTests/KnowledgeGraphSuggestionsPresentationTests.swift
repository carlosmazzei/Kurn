import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K7.4: the suggestions the Graph Explorer lists beside the stated relationships.
@MainActor
struct KnowledgeGraphSuggestionsPresentationTests {
    private static let meeting = UUID(), now = Date(timeIntervalSince1970: 1_795_600_000)
    private static let alpha = UUID(), beta = UUID(), gamma = UUID(), sam = UUID(), samAlias = UUID()
    private static let action = UUID(), owner = UUID()

    private static func fact(_ subject: UUID, _ predicate: KnowledgePredicate, object: UUID? = nil,
                             value: KnowledgeTypedValue? = nil) -> KnowledgeWikiSnapshot.Fact {
        KnowledgeWikiSnapshot.Fact(
            id: UUID(), subjectID: subject, predicate: predicate, objectID: object, value: value,
            qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                              confidence: .medium, review: .machineExtracted),
            source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_790_000_000), evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                      attributedSpeaker: "Speaker 1"),
            ]))
    }

    private static func pages() throws -> [KnowledgeWikiPage] {
        let due = KnowledgeTemporalValue(text: "2026-12-01", precision: .day).map { KnowledgeTypedValue.date($0) }
        return try KnowledgeWikiProjector.project(.init(revision: 1, entities: [
            .init(id: alpha, kind: .project, name: "Alpha"), .init(id: beta, kind: .project, name: "Beta"),
            .init(id: gamma, kind: .project, name: "Gamma"),
            .init(id: sam, kind: .person, name: "Sam Rivera", aliases: ["Sam R"]), .init(id: samAlias, kind: .person, name: "Sam R"),
            .init(id: action, kind: .actionItem, name: "Migrate billing"), .init(id: owner, kind: .person, name: "Avery"),
        ], facts: [
            fact(alpha, .blocks, object: beta), fact(beta, .blocks, object: gamma),
            fact(sam, .relatesTo, object: alpha), fact(samAlias, .relatesTo, object: alpha),
            fact(action, .assignedTo, object: owner), fact(action, .dueOn, value: due),
        ]))
    }

    @Test func eachKindIsListedWithItsReasonAndAPassageWhenItFollowsFromClaims() throws {
        let all: Set = [Self.alpha, Self.beta, Self.gamma, Self.sam, Self.samAlias, Self.action, Self.owner]
        let list = KnowledgeGraphPresentation.suggestions(pages: try Self.pages(), touching: all, now: Self.now)
        let edge = try #require(list.first { $0.kind == .derivedEdge })
        #expect(edge.text.contains("Alpha") && edge.text.contains("Gamma") && edge.evidence != nil)
        #expect(edge.detail == String(format: KnowledgeGraphPresentation.copy("suggestion.derived"), 2))
        let commitment = try #require(list.first { $0.kind == .commitment })
        #expect(commitment.text.contains("Avery") && commitment.text.contains("Migrate billing") && commitment.text.contains("2026-12-01"))
        #expect(commitment.evidence != nil)
        let same = try #require(list.first { $0.kind == .sameAs })
        #expect(same.text.contains("Sam Rivera") && same.text.contains("Sam R") && same.evidence == nil)
        // Rows are told apart by identity, so a list can be keyed by them.
        #expect(Set(list.map(\.id)).count == list.count)
    }

    @Test func onlyWhatTouchesTheShownNodesIsListed() throws {
        let pages = try Self.pages()
        #expect(KnowledgeGraphPresentation.suggestions(pages: pages, touching: [UUID()], now: Self.now).isEmpty)
        let onlyAction = KnowledgeGraphPresentation.suggestions(pages: pages, touching: [Self.action], now: Self.now)
        #expect(onlyAction.map(\.kind) == [.commitment])
    }
}

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeEntityAskTests {
    private let subject = UUID()

    private func fact(meeting: UUID) -> KnowledgeWikiSnapshot.Fact {
        .init(id: UUID(), subjectID: subject, predicate: .hasStatus, value: .enumeration("open"),
            qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalProposal,
                authority: .unverified, confidence: .low, review: .machineExtracted),
            source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_000), evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["anchor"], quote: "Open.",
                    startMs: 0, endMs: 1_000, attributedSpeaker: "Speaker 1")]))
    }

    private func page(_ meetings: [UUID]) throws -> KnowledgeWikiPage {
        let entity = KnowledgeWikiSnapshot.Entity(id: subject, kind: .project, name: "Example", aliases: [], targetID: nil)
        let pages = try KnowledgeWikiProjector.project(.init(revision: 1, entities: [entity], facts: meetings.map(fact)))
        return try #require(pages.first)
    }

    @Test func scopesTheQuestionToEveryDistinctSourceMeeting() throws {
        let first = UUID(), second = UUID()
        let scope = try #require(KnowledgeEntityAsk.scope(page([first, second, first])))
        #expect(scope.kind == .meetings)
        #expect(scope.selectedIDs == [first, second])
        #expect(scope.parts.contains(.knowledge))
    }

    @Test func aPageWithoutFactsHasNothingToAskOver() throws {
        let entity = KnowledgeWikiSnapshot.Entity(id: subject, kind: .project, name: "Example")
        #expect(KnowledgeEntityAsk.scope(KnowledgeWikiPage(entity: entity, revision: 1, sections: [], narrative: nil)) == nil)
    }
}

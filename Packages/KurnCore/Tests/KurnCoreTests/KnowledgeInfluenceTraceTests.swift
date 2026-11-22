import Foundation
import Testing
@testable import KurnCore

struct KnowledgeInfluenceTraceTests {
    private let decision = UUID(), replacement = UUID()

    private func fact(_ subject: UUID, _ predicate: KnowledgePredicate, object: UUID? = nil, value: KnowledgeTypedValue? = nil,
                      recorded: TimeInterval, speakers: [String]) -> KnowledgeWikiSnapshot.Fact {
        .init(id: UUID(), subjectID: subject, predicate: predicate, objectID: object, value: value,
            qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalProposal,
                authority: .unverified, confidence: .low, review: .machineExtracted),
            source: .init(meetingID: UUID(), recordedAt: Date(timeIntervalSince1970: recorded), evidence: speakers.map {
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["anchor"], quote: "Said.",
                    startMs: 0, endMs: 1_000, attributedSpeaker: $0)
            }))
    }

    @Test func stepsFollowTheirOrderAndNameWhatTheyReplace() throws {
        let opened = fact(decision, .hasStatus, value: .enumeration("proposed"), recorded: 1_000, speakers: ["Ana"])
        let approved = fact(decision, .hasStatus, value: .enumeration("approved"), recorded: 2_000, speakers: ["Bo", "Ana", "Bo"])
        let superseded = fact(replacement, .supersedes, object: decision, recorded: 3_000, speakers: ["Cy"])
        let entities = [KnowledgeWikiSnapshot.Entity(id: decision, kind: .project, name: "Old plan"),
                        KnowledgeWikiSnapshot.Entity(id: replacement, kind: .project, name: "New plan")]
        let pages = try KnowledgeWikiProjector.project(.init(revision: 1, entities: entities,
                                                             facts: [superseded, approved, opened]))
        let steps = KnowledgeInfluenceTrace.trace(entityID: decision, pages: pages)
        #expect(steps.map { $0.entry.fact.id } == [opened.id, approved.id, superseded.id])
        #expect(steps.map { $0.replaces } == [[UUID]]([[], [opened.id], []]))
        #expect(steps[1].speakers == ["Bo", "Ana"])
    }

    @Test func anEntityWithoutClaimsHasNoTrace() {
        #expect(KnowledgeInfluenceTrace.trace(entityID: UUID(), pages: []).isEmpty)
    }
}

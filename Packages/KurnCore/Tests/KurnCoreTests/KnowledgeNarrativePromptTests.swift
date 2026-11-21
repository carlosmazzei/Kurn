import Foundation
import Testing
@testable import KurnCore

struct KnowledgeNarrativePromptTests {
    private let project = UUID()

    private func page(claims: Int = 2) throws -> KnowledgeWikiPage {
        let entity = KnowledgeWikiSnapshot.Entity(id: project, kind: .project, name: "Example portal")
        let qualifiers = KnowledgeWikiSnapshot.Qualifiers(modality: .reported, polarity: .positive, claimKind: .internalProposal,
            authority: .unverified, confidence: .low, review: .machineExtracted)
        func fact(_ value: String, at seconds: TimeInterval = 1_000) -> KnowledgeWikiSnapshot.Fact {
            .init(id: UUID(), subjectID: project, predicate: .hasStatus, value: .enumeration(value), qualifiers: qualifiers,
                source: .init(meetingID: UUID(), recordedAt: Date(timeIntervalSince1970: seconds), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["anchor"], quote: "Said.", startMs: 0, endMs: 1_000,
                        attributedSpeaker: "Speaker 1")]))
        }
        let pages = try KnowledgeWikiProjector.project(.init(revision: 1, entities: [entity], facts: claims == 2 ? [fact("open"), fact("blocked")]
            : (0..<claims).map { fact("state\($0)", at: 1_000 + TimeInterval($0)) }))
        return try #require(pages.first)
    }

    @Test func theRequestNumbersEveryClaim() throws {
        let page = try page()
        let request = try #require(KnowledgeNarrativePrompt.request(page))
        #expect(Set(request.references.values) == Set(page.sections.flatMap(\.entries).map(\.fact.id)))
        #expect(request.userPrompt.contains("[c1] Example portal hasStatus") && request.userPrompt.contains("[c2]"))
    }

    @Test func parsingKeepsCitedParagraphsThatValidateAgainstThePage() throws {
        let page = try page()
        let request = try #require(KnowledgeNarrativePrompt.request(page))
        let output = "The portal was open [c1], then blocked [c2][c1].\n\nUncited filler.\n\nUnknown [c9]."
        let narrative = try #require(KnowledgeNarrativePrompt.parse(output, entityID: project, references: request.references))
        #expect(narrative.paragraphs.count == 1)
        #expect(narrative.paragraphs[0].text == "The portal was open, then blocked.")
        #expect(narrative.paragraphs[0].assertionIDs == [request.references["c1"], request.references["c2"]].compactMap { $0 })
        let entity = page.entity
        let snapshot = KnowledgeWikiSnapshot(revision: 1, entities: [entity],
                                             facts: page.sections.flatMap(\.entries).map(\.fact))
        #expect(try KnowledgeWikiProjector.project(snapshot, narratives: [narrative]).first?.narrative == narrative)
    }

    @Test func aLargePageKeepsItsMostRecentClaims() throws {
        let page = try page(claims: 45)
        let request = try #require(KnowledgeNarrativePrompt.request(page))
        let entries = page.sections.flatMap(\.entries)
        let newest = entries.sorted { $0.fact.source.recordedAt > $1.fact.source.recordedAt }.prefix(40).map(\.fact.id)
        #expect(request.references.count == 40 && Set(request.references.values) == Set(newest))
    }

    @Test func aParagraphCitingMoreThanTheLimitIsDroppedNotTruncated() {
        let references = Dictionary(uniqueKeysWithValues: (1...17).map { ("c\($0)", UUID()) })
        let output = "Too many " + (1...17).map { "[c\($0)]" }.joined() + "."
        #expect(KnowledgeNarrativePrompt.parse(output, entityID: project, references: references) == nil)
    }

    @Test func outputWithoutCitationsGivesNoNarrative() throws {
        #expect(KnowledgeNarrativePrompt.parse("Nothing cited here.", entityID: project, references: ["c1": UUID()]) == nil)
        #expect(KnowledgeNarrativePrompt.request(KnowledgeWikiPage(entity: .init(id: project, kind: .project, name: "Empty"),
                                                                   revision: 1, sections: [], narrative: nil)) == nil)
    }
}

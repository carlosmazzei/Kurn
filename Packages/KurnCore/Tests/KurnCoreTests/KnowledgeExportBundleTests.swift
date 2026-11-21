import Foundation
import Testing
@testable import KurnCore

struct KnowledgeExportBundleTests {
    private let project = UUID(), team = UUID(), meeting = UUID()

    private func pages() throws -> [KnowledgeWikiPage] {
        let entities = [KnowledgeWikiSnapshot.Entity(id: project, kind: .project, name: "Example portal"),
                        KnowledgeWikiSnapshot.Entity(id: team, kind: .organization, name: "Platform team")]
        let qualifiers = KnowledgeWikiSnapshot.Qualifiers(modality: .reported, polarity: .positive, claimKind: .internalProposal,
            authority: .unverified, confidence: .low, review: .machineExtracted)
        func source() -> KnowledgeWikiSnapshot.Source { KnowledgeWikiSnapshot.Source(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_000), evidence: [
            .init(id: UUID(), recordingID: UUID(), segmentIDs: ["anchor"], quote: "The team blocks the portal.",
                startMs: 0, endMs: 1_000, attributedSpeaker: "Speaker 1")]) }
        let facts = [KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: team, predicate: .blocks, objectID: project,
                                                qualifiers: qualifiers, source: source()),
                     KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: project, predicate: .hasStatus, value: .enumeration("open"),
                                                qualifiers: qualifiers, source: source())]
        return try KnowledgeWikiProjector.project(.init(revision: 3, entities: entities, facts: facts))
    }

    @Test func holdsEveryEntityClaimAndEvidenceOnceAndRoundTrips() throws {
        let pages = try pages()
        let bundle = KnowledgeExportBundle(revision: 3, exportedAt: Date(timeIntervalSince1970: 2_000),
                                           meetingTitles: [meeting: "Weekly sync"], pages: pages)
        #expect(bundle.format == "kurn.knowledge-export" && bundle.schema == 1 && bundle.revision == 3)
        #expect(Set(bundle.entities.map(\.id)) == [project, team])
        #expect(bundle.facts.count == 2 && bundle.facts.allSatisfy { $0.source.evidence.count == 1 })
        #expect(bundle.meetings == [.init(id: meeting, title: "Weekly sync")])
        #expect(try KnowledgeExportBundle.decode(bundle.encoded()) == bundle)
    }

    @Test func everyClaimReferenceResolvesToAnExportedEntity() throws {
        let bundle = KnowledgeExportBundle(revision: 3, exportedAt: Date(timeIntervalSince1970: 2_000),
                                           meetingTitles: [meeting: "Weekly sync"], pages: try pages())
        let ids = Set(bundle.entities.map(\.id))
        #expect(bundle.facts.allSatisfy { ids.contains($0.subjectID) && ($0.objectID.map(ids.contains) ?? true) })
    }

    @Test func theSameKnowledgeEncodesToTheSameBytes() throws {
        let pages = try pages()
        let date = Date(timeIntervalSince1970: 2_000)
        let forward = KnowledgeExportBundle(revision: 3, exportedAt: date, meetingTitles: [meeting: "Weekly sync"], pages: pages)
        let reversed = KnowledgeExportBundle(revision: 3, exportedAt: date, meetingTitles: [meeting: "Weekly sync"], pages: pages.reversed())
        #expect(try forward.encoded() == reversed.encoded())
    }

    @Test func refusesAnotherFormatOrSchema() throws {
        let bundle = KnowledgeExportBundle(revision: 1, exportedAt: Date(timeIntervalSince1970: 0), meetingTitles: [:], pages: [])
        let text = try #require(String(data: bundle.encoded(), encoding: .utf8))
        for changed in [text.replacingOccurrences(of: "\"schema\" : 1", with: "\"schema\" : 2"),
                        text.replacingOccurrences(of: "kurn.knowledge-export", with: "other")] {
            #expect(throws: KnowledgeExportBundleError.unsupported) { try KnowledgeExportBundle.decode(Data(changed.utf8)) }
        }
    }
}

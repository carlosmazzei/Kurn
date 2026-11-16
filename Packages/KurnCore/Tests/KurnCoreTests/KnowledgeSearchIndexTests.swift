import Foundation
import Testing
@testable import KurnCore

struct KnowledgeSearchIndexTests {
    let meeting = UUID()
    let entity = UUID()

    func pages(revision: Int = 1, quote: String = "A decisão NÃO aprovou o orçamento. 预算未获批准。") throws -> [KnowledgeWikiPage] {
        let fact = KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: entity, predicate: .hasStatus, value: .enumeration("open"),
            qualifiers: .init(modality: .proposed, polarity: .negative, claimKind: .internalProposal,
                authority: .unverified, confidence: .low, review: .machineExtracted),
            source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1), evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: quote,
                    startMs: 0, endMs: 1_000, attributedSpeaker: "Example speaker")]))
        return try KnowledgeWikiProjector.project(.init(revision: revision, entities: [
            .init(id: entity, kind: .project, name: "Example portal", aliases: ["Órion workspace"])], facts: [fact]))
    }

    @Test func typedDocumentsRetainScopeRevisionAndEvidenceWithoutInventingTranscriptTimes() throws {
        let pages = try pages(revision: 7)
        let index = try KnowledgeSearchIndex(pages: pages, meetingIDs: [meeting])
        #expect(Set(index.documents.map(\.kind)) == [.page, .alias, .assertion])
        #expect(Set(index.documents.map(\.id)).count == 3)
        #expect(index.documents.allSatisfy { $0.meetingIDs == [meeting] && $0.revision == 7 })
        let assertion = try #require(index.documents.first { $0.kind == .assertion })
        #expect(assertion.assertionID == pages[0].sections[0].entries[0].fact.id)
        #expect(assertion.evidenceID == pages[0].sections[0].entries[0].fact.source.evidence[0].id)
        #expect(assertion.text.contains("negative") && assertion.text.contains("proposed"))
    }

    @Test func aliasesAccentCaseAndUnicodeQuotesWorkWithoutDenseVectors() throws {
        let index = try KnowledgeSearchIndex(pages: pages(), meetingIDs: [meeting])
        #expect(try index.search(query: "ORION").contains { $0.kind == .alias })
        #expect(try index.search(query: "decisao").contains { $0.kind == .assertion })
        #expect(try index.search(query: "预算").contains { $0.kind == .assertion })
        #expect(try index.search(query: "Example portal").contains { $0.kind == .page })
        #expect(try index.search(query: "missing term").isEmpty)
    }

    @Test func refusesForeignEmptyDuplicateAndMixedRevisionScopes() throws {
        let pages = try pages()
        #expect(throws: KnowledgeSearchError.invalidScope) { try KnowledgeSearchIndex(pages: pages, meetingIDs: []) }
        #expect(throws: KnowledgeSearchError.invalidScope) { try KnowledgeSearchIndex(pages: pages, meetingIDs: [UUID()]) }
        #expect(throws: KnowledgeSearchError.invalidScope) { try KnowledgeSearchIndex(pages: pages + pages, meetingIDs: [meeting]) }
        let other = KnowledgeSearchIndexTests()
        let mixed = pages + (try other.pages(revision: 2))
        #expect(throws: KnowledgeSearchError.invalidScope) {
            try KnowledgeSearchIndex(pages: mixed, meetingIDs: [meeting, other.meeting])
        }
        #expect(throws: KnowledgeSearchError.invalidScope) {
            try KnowledgeSearchIndex(pages: pages, meetingIDs: Set((0..<17).map { _ in UUID() }))
        }
    }

    @Test func emptyOversizedAndBoundedQueriesNeverSilentlyTruncate() throws {
        let index = try KnowledgeSearchIndex(pages: pages(), meetingIDs: [meeting])
        #expect(try index.search(query: "  \n").isEmpty)
        #expect(try index.search(query: "portal", limit: 0).isEmpty)
        #expect(try index.search(query: "portal", limit: 1).count == 1)
        #expect(throws: KnowledgeSearchError.invalidQuery) { try index.search(query: String(repeating: "a", count: 257)) }
        #expect(throws: KnowledgeSearchError.indexLimit) {
            try KnowledgeSearchIndex(pages: self.pages(quote: String(repeating: "x", count: KnowledgeSearchIndex.byteLimit)), meetingIDs: [meeting])
        }
    }

    @Test func namesAndStableIDsBreakTiesIndependentlyOfPageInputOrder() throws {
        let other = KnowledgeSearchIndexTests()
        let page = try pages() + other.pages()
        let scope: Set<UUID> = [meeting, other.meeting]
        let index = try KnowledgeSearchIndex(pages: page, meetingIDs: scope)
        let reversed = try KnowledgeSearchIndex(pages: Array(page.reversed()), meetingIDs: scope)
        #expect(try index.search(query: "portal") == reversed.search(query: "portal"))
        let expected = try index.search(query: "portal").map(\.id)
        for _ in 0..<10 { #expect(try index.search(query: "portal").map(\.id) == expected) }
        let dense = try index.search(query: "unrelated", denseOrder: [999, -1, 1, 1])
        #expect(dense.map(\.id) == [index.documents[1].id])
    }

    @Test func snippetsAreLiteralBoundedAndNeverRenderModelMarkup() throws {
        let hostile = "<img src=https://example.invalid> [link](https://example.invalid) " + String(repeating: "x", count: 300)
        let index = try KnowledgeSearchIndex(pages: pages(quote: hostile), meetingIDs: [meeting])
        let result = try #require(index.search(query: "img").first)
        #expect(result.snippet(query: "img").hasPrefix("<img"))
        #expect(result.snippet(query: "img").count == 241)
    }

    @Test func sharedRankerIsDeterministicAndDoesNotCountDuplicateDenseRanksTwice() {
        #expect(HybridSearchRanking.bm25Order(query: "same", texts: ["same", "same"]) == [0, 1])
        let ranked = HybridSearchRanking.reciprocalRankFusion([[0, 0], [1]])
        #expect(ranked.map(\.index) == [0, 1])
        #expect(ranked[0].score == ranked[1].score)
        #expect(HybridSearchRanking.reciprocalRankFusion([[1]], k: -1).isEmpty)
    }
}

import Foundation
import Testing
@testable import KurnCore

struct KnowledgeReviewProjectionTests {
    let entity = UUID()
    let meeting = UUID()

    private func fact(polarity: KnowledgePolarity = .positive, modality: KnowledgeModality = .reported,
                      from: KnowledgeTemporalValue? = nil, value: KnowledgeTypedValue = .enumeration("open")) -> KnowledgeWikiSnapshot.Fact {
        .init(id: UUID(), subjectID: entity, predicate: value.type == .date ? .dueOn : .hasStatus, value: value,
            qualifiers: .init(modality: modality, polarity: polarity, claimKind: .internalStatusReport,
                authority: .attributed, confidence: .medium, review: .machineExtracted, validFrom: from),
            source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1), evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: [UUID().uuidString.lowercased()], quote: "Synthetic review passage.",
                    startMs: 0, endMs: 1_000, attributedSpeaker: "Speaker 1")]))
    }

    private func pages(_ facts: [KnowledgeWikiSnapshot.Fact]) throws -> [KnowledgeWikiPage] {
        try KnowledgeWikiProjector.project(.init(revision: 1, entities: [.init(id: entity, kind: .project, name: "Example project")], facts: facts))
    }

    @Test func exactOpposingClaimsCreateOneStableSourceBackedHint() throws {
        let facts = [fact(), fact(polarity: .negative)]
        let result = try KnowledgeReviewProjection.hints(pages: pages(facts))
        #expect(result.count == 1)
        #expect(result.first?.kind == .conflict)
        #expect(Set(result.first?.assertionIDs ?? []) == Set(facts.map(\.id)))
        #expect(try KnowledgeReviewProjection.hints(pages: pages(facts.reversed())) == result)
    }

    @Test func differentIntervalsAndModalitiesDoNotChooseTheLatestClaim() throws {
        let date = try #require(KnowledgeTemporalValue(text: "2026-11-16", precision: .day))
        #expect(try KnowledgeReviewProjection.hints(pages: pages([fact(), fact(polarity: .negative, from: date)])).isEmpty)
        #expect(try KnowledgeReviewProjection.hints(pages: pages([fact(), fact(polarity: .negative, modality: .hypothetical)])).isEmpty)
        #expect(try KnowledgeReviewProjection.hints(pages: pages([fact(), fact()])).isEmpty)
    }

    @Test func monthPrecisionIsPreservedAndUnknownDatesAreNotInvented() throws {
        let month = try #require(KnowledgeTemporalValue(text: "2026-11", precision: .month))
        let input = fact(from: month)
        let date = fact(value: .date(month))
        let output = try KnowledgeReviewProjection.hints(pages: pages([input, date, fact()]))
        #expect(output.count == 2)
        #expect(output.allSatisfy { $0.kind == .uncertainDate })
        #expect(Set(output.flatMap(\.assertionIDs)) == [input.id, date.id])
        #expect(input.qualifiers.validFrom?.precision == .month)
        #expect(date.value == .date(month))
    }

    @Test func cancellationDoesNotProduceAReview() async throws {
        let input = try pages([fact()])
        let (stream, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { break }
            return try KnowledgeReviewProjection.hints(pages: input)
        }
        task.cancel(); signal.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func oversizedPageInputIsRefusedBeforeReviewingContent() throws {
        #expect(try KnowledgeReviewProjection.hints(pages: []).isEmpty)
        let page = try #require(pages([fact()]).first)
        #expect(throws: KnowledgeMaintenanceError.limitExceeded) {
            try KnowledgeReviewProjection.hints(pages: Array(repeating: page, count: KnowledgeWikiProjector.entityLimit + 1))
        }
    }
}

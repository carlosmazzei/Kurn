//
//  SummaryMapCheckpointTests.swift
//  KurnTests
//
//  H4: a staged summary/wiki run's map-stage checkpoint must only resume a
//  run with the exact same content, provider, model, and block count — and
//  must never seed a resume when its own numbers don't add up.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct SummaryMapCheckpointTests {

    private func checkpoint(
        contentDigest: String = "abc123",
        providerID: String = AIProvider.openAI.id,
        model: String = "gpt-4o",
        totalBlocks: Int = 3,
        completedNotes: [String] = ["note 1", "note 2"]
    ) -> SummaryMapCheckpoint {
        SummaryMapCheckpoint(
            contentDigest: contentDigest,
            providerID: providerID,
            model: model,
            totalBlocks: totalBlocks,
            completedNotes: completedNotes
        )
    }

    @Test func matchesRequiresExactIdentity() {
        let cp = checkpoint()
        #expect(cp.matches(contentDigest: "abc123", providerID: AIProvider.openAI.id, model: "gpt-4o", totalBlocks: 3))

        #expect(!cp.matches(contentDigest: "different", providerID: AIProvider.openAI.id, model: "gpt-4o", totalBlocks: 3))
        #expect(!cp.matches(contentDigest: "abc123", providerID: AIProvider.groq.id, model: "gpt-4o", totalBlocks: 3))
        #expect(!cp.matches(contentDigest: "abc123", providerID: AIProvider.openAI.id, model: "gpt-4o-mini", totalBlocks: 3))
        #expect(!cp.matches(contentDigest: "abc123", providerID: AIProvider.openAI.id, model: "gpt-4o", totalBlocks: 4))
    }

    @Test func structurallyValidCheckpointPasses() {
        #expect(checkpoint().isStructurallyValid)
        #expect(checkpoint(totalBlocks: 2, completedNotes: []).isStructurallyValid)
        #expect(checkpoint(totalBlocks: 2, completedNotes: ["a", "b"]).isStructurallyValid)
    }

    @Test func moreCompletedNotesThanTotalBlocksIsInvalid() {
        #expect(!checkpoint(totalBlocks: 1, completedNotes: ["a", "b"]).isStructurallyValid)
    }

    @Test func negativeTotalBlocksIsInvalid() {
        #expect(!checkpoint(totalBlocks: -1, completedNotes: []).isStructurallyValid)
    }

    @Test func codableRoundTripPreservesEverything() throws {
        let original = checkpoint()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SummaryMapCheckpoint.self, from: data)

        #expect(decoded.contentDigest == original.contentDigest)
        #expect(decoded.providerID == original.providerID)
        #expect(decoded.model == original.model)
        #expect(decoded.totalBlocks == original.totalBlocks)
        #expect(decoded.completedNotes == original.completedNotes)
    }
}

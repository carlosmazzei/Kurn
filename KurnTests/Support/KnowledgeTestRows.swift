//
//  KnowledgeTestRows.swift
//  KurnTests
//
//  One row of every Knowledge Engine model (`KurnSchemaV7`), linked by ID to a
//  meeting, for suites that need the canonical layer populated: the V6 → V7
//  migration and "Delete all data". Synthetic content only.
//

import Foundation
import KurnCore
import SwiftData
@testable import Kurn

@MainActor
enum KnowledgeTestRows {
    /// Every knowledge model's type, so a suite can check each one by count.
    static let modelTypes: [any PersistentModel.Type] = [
        KnowledgeEntity.self, KnowledgeAssertion.self, KnowledgeEvidence.self, KnowledgeEvent.self,
        KnowledgeRelation.self, KnowledgeJob.self, KnowledgeRevision.self, KnowledgeReview.self,
        KnowledgeContext.self, SourceContextLink.self
    ]

    @discardableResult
    static func insertOneOfEach(meetingID: UUID, in context: ModelContext) -> KnowledgeAssertion {
        let revisionID = UUID()
        let project = KnowledgeEntity(kind: .project, canonicalName: "Example Portal", normalizedName: "example portal")
        let team = KnowledgeEntity(kind: .team, canonicalName: "Platform", normalizedName: "platform")
        let occasion = KnowledgeContext(kind: .internalMeeting, name: "Weekly sync")
        let job = KnowledgeJob(
            idempotencyKey: "meeting:\(meetingID):fingerprint:extractor-v1:1.6.0",
            kind: .extraction, meetingID: meetingID, pipelineVersion: "extractor-v1"
        )
        let assertion = KnowledgeAssertion(
            subjectEntityID: team.id, predicate: .owns, objectEntityID: project.id,
            modality: .agreed, claimKind: .internalDecision, confidenceBand: .high,
            validFrom: KnowledgeTemporalValue(text: "2026-11", precision: .month),
            sourceMeetingID: meetingID, contextID: occasion.id, revisionID: revisionID,
            extractorVersion: "extractor-v1"
        )
        context.insert(project)
        context.insert(team)
        context.insert(occasion)
        context.insert(job)
        context.insert(assertion)
        context.insert(KnowledgeEvidence(
            assertionID: assertion.id, meetingID: meetingID, transcriptFingerprint: "fingerprint",
            segmentIDsData: JSONStorage.encode(["s1"]), quote: "Platform owns the portal.",
            quoteHash: "hash", startMs: 0, endMs: 4_000
        ))
        context.insert(KnowledgeEvent(
            entityID: project.id, kind: .assigned, assertionID: assertion.id,
            occurredAt: KnowledgeTemporalValue(text: "2026-11-05", precision: .day),
            sourceMeetingID: meetingID, revisionID: revisionID
        ))
        context.insert(KnowledgeRelation(
            subjectEntityID: team.id, predicate: .owns, objectEntityID: project.id,
            assertionID: assertion.id, revisionID: revisionID
        ))
        context.insert(KnowledgeRevision(id: revisionID, number: 1, jobID: job.id, policyRevisionKey: "default:1", assertionCount: 1))
        context.insert(KnowledgeReview(kind: .mergeCandidate, subjectIDsData: JSONStorage.encode([project.id, team.id])))
        context.insert(SourceContextLink(meetingID: meetingID, contextID: occasion.id))
        return assertion
    }

    /// How many rows of `type` `insertOneOfEach` writes: two entities (an
    /// assertion needs a subject and an object), one of everything else.
    static func insertedCount(of type: any PersistentModel.Type) -> Int {
        ObjectIdentifier(type) == ObjectIdentifier(KnowledgeEntity.self) ? 2 : 1
    }

    static func count(_ type: any PersistentModel.Type, in context: ModelContext) throws -> Int {
        try countRows(of: type, in: context)
    }

    private static func countRows<Model: PersistentModel>(of type: Model.Type, in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<Model>())
    }
}

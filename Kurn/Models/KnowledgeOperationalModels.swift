//
//  KnowledgeOperationalModels.swift
//  Kurn
//
//  What runs and records the Knowledge Engine's canonical layer
//  (`KnowledgeCanonicalModels.swift`): the job queue, the commit log of
//  canonical revisions with its projection outbox, the review inbox, and the
//  contexts a source was recorded in. Added in `KurnSchemaV7`; related by
//  persisted UUIDs, never by relationships to `Meeting`.
//
//  A meeting with no `SourceContextLink` is in context `unknown` — every
//  meeting recorded before knowledge existed — so upgrading writes nothing
//  and the migration stays lightweight.
//

import Foundation
import KurnCore
import SwiftData

@Model
final class KnowledgeJob {
    #Index<KnowledgeJob>([\.stateRaw, \.createdAt], [\.meetingID])
    @Attribute(.unique) var id: UUID
    /// `scope + meetingID + transcriptFingerprint + extractorVersion +
    /// schemaVersion` (K1.5): the same work is never queued twice.
    @Attribute(.unique) var idempotencyKey: String
    var kindRaw: String
    var stateRaw: String
    var meetingID: UUID?
    var attempts: Int
    /// The pipeline version that produced it (the old `wiki-vN` tag included).
    var pipelineVersion: String
    /// Full context or semantic blocks, and what was covered: recorded, never
    /// a silent truncation (ADR-004).
    var strategyRaw: String?
    var coverageData: Data?
    var checkpointData: Data?
    /// A fixed, log-safe code; never error text.
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        idempotencyKey: String,
        kind: KnowledgeJobKind,
        meetingID: UUID? = nil,
        pipelineVersion: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.kindRaw = kind.rawValue
        self.stateRaw = KnowledgeJobState.pending.rawValue
        self.meetingID = meetingID
        self.attempts = 0
        self.pipelineVersion = pipelineVersion
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// One committed canonical revision. Projections are rebuilt from a revision,
/// and `projectionPending` is the outbox a projection job drains.
@Model
final class KnowledgeRevision {
    @Attribute(.unique) var id: UUID
    /// Strictly increasing; re-checked at commit so two writers never race.
    @Attribute(.unique) var number: Int
    var jobID: UUID?
    /// `KnowledgePolicyEvaluator.revisionKey` of the policies it was built under.
    var policyRevisionKey: String
    var assertionCount: Int
    var projectionPending: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        number: Int,
        jobID: UUID? = nil,
        policyRevisionKey: String,
        assertionCount: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.number = number
        self.jobID = jobID
        self.policyRevisionKey = policyRevisionKey
        self.assertionCount = assertionCount
        self.projectionPending = true
        self.createdAt = createdAt
    }
}

/// An item in the review inbox. Resolving keeps the item, so it can be undone.
@Model
final class KnowledgeReview {
    #Index<KnowledgeReview>([\.stateRaw, \.createdAt])
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var stateRaw: String
    /// JSON `[UUID]`: the entities or assertions it concerns.
    var subjectIDsData: Data
    /// Kind-specific detail, JSON.
    var payloadData: Data?
    var createdAt: Date
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        kind: KnowledgeReviewItemKind,
        subjectIDsData: Data,
        payloadData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.stateRaw = KnowledgeReviewItemState.open.rawValue
        self.subjectIDsData = subjectIDsData
        self.payloadData = payloadData
        self.createdAt = createdAt
        self.resolvedAt = nil
    }
}

/// The occasion a source was recorded at (spec §20.1): an internal meeting, a
/// conference session, a vendor discussion. Its classification is inherited
/// by everything derived from its sources.
@Model
final class KnowledgeContext {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var name: String
    /// `KnowledgeClassification` raw value.
    var classificationRaw: Int
    /// The `KnowledgeProcessingPolicy` that governs it, when one is named.
    var policyID: String?
    var startedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: KnowledgeContextKind,
        name: String,
        classification: KnowledgeClassification = .`internal`,
        policyID: String? = nil,
        startedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.classificationRaw = classification.rawValue
        self.policyID = policyID
        self.startedAt = startedAt
        self.createdAt = createdAt
    }
}

/// Places a meeting in a context. No link means context `unknown`.
@Model
final class SourceContextLink {
    #Index<SourceContextLink>([\.meetingID], [\.contextID])
    @Attribute(.unique) var id: UUID
    var meetingID: UUID
    var contextID: UUID
    /// JSON `[String: [KnowledgeOrganizationRole]]` keyed by organization name:
    /// presence never implies employment.
    var organizationRolesData: Data?
    var createdAt: Date

    init(id: UUID = UUID(), meetingID: UUID, contextID: UUID, organizationRolesData: Data? = nil, createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.contextID = contextID
        self.organizationRolesData = organizationRolesData
        self.createdAt = createdAt
    }
}

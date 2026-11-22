//
//  KnowledgeCanonicalModels.swift
//  Kurn
//
//  The Knowledge Engine's canonical layer (CLAUDE.md, "Knowledge Engine
//  decisions"): entities, the attributed and evidence-backed assertions about
//  them, the evidence itself, the events states are projected from, and the
//  relations derived from relational assertions. Added in `KurnSchemaV7`.
//
//  Rows relate by persisted UUIDs, never by `@Relationship` to `Meeting`: an
//  entity is shared across meetings, so a cascade from one meeting would
//  destroy knowledge another still supports. Deletion is explicit (K2.8).
//  Every closed vocabulary is stored as its KurnCore raw value. Times follow
//  the bitemporal rule: valid time is the stated `KnowledgeTemporalValue`
//  text at its precision, transaction time is `recordedAt`/`retractedAt`.
//  Transcript-derived text lives only in this store, encrypted at rest with
//  everything else (`ModelStoreProtection`).
//

import Foundation
import KurnCore
import SwiftData

@Model
final class KnowledgeEntity {
    #Index<KnowledgeEntity>([\.kindRaw, \.normalizedName], [\.mergedIntoID])
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var canonicalName: String
    /// Case- and accent-folded name, for lookup during resolution.
    var normalizedName: String
    /// JSON `[String]` of other names the entity is known by.
    var aliasesData: Data
    var reviewStateRaw: String
    /// Set when the entity was merged: a redirect, so the merge is reversible.
    var mergedIntoID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: KnowledgeEntityKind,
        canonicalName: String,
        normalizedName: String,
        aliasesData: Data = Data(),
        reviewState: KnowledgeReviewState = .machineExtracted,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.canonicalName = canonicalName
        self.normalizedName = normalizedName
        self.aliasesData = aliasesData
        self.reviewStateRaw = reviewState.rawValue
        self.mergedIntoID = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

@Model
final class KnowledgeAssertion {
    #Index<KnowledgeAssertion>([\.subjectEntityID, \.predicateRaw], [\.objectEntityID], [\.sourceMeetingID], [\.revisionID])
    @Attribute(.unique) var id: UUID
    var subjectEntityID: UUID
    var predicateRaw: String
    /// The registry version the predicate was validated under.
    var predicateRegistryVersion: Int
    var objectEntityID: UUID?
    /// JSON `KnowledgeTypedValue` when the object is a value.
    var valueData: Data?
    var modalityRaw: String
    var polarityRaw: String
    var claimKindRaw: String
    var authorityStatusRaw: String
    var confidenceBandRaw: String
    var reviewStateRaw: String
    /// Valid time: `KnowledgeTemporalValue` text and precision, half-open.
    var validFromText: String?
    var validFromPrecisionRaw: String?
    var validToText: String?
    var validToPrecisionRaw: String?
    /// Transaction time: when the store learned it, and when it stopped
    /// believing it (a later revision superseded or invalidated it).
    var recordedAt: Date
    var retractedAt: Date?
    var sourceMeetingID: UUID
    var contextID: UUID?
    var revisionID: UUID
    var extractorVersion: String

    // swiftlint:disable:next function_parameter_count
    init(
        id: UUID = UUID(),
        subjectEntityID: UUID,
        predicate: KnowledgePredicate,
        objectEntityID: UUID? = nil,
        valueData: Data? = nil,
        modality: KnowledgeModality,
        polarity: KnowledgePolarity = .positive,
        claimKind: KnowledgeClaimKind,
        authorityStatus: KnowledgeAuthorityStatus = .attributed,
        confidenceBand: KnowledgeConfidenceBand,
        reviewState: KnowledgeReviewState = .machineExtracted,
        validFrom: KnowledgeTemporalValue? = nil,
        validTo: KnowledgeTemporalValue? = nil,
        recordedAt: Date = Date(),
        sourceMeetingID: UUID,
        contextID: UUID? = nil,
        revisionID: UUID,
        extractorVersion: String
    ) {
        self.id = id
        self.subjectEntityID = subjectEntityID
        self.predicateRaw = predicate.rawValue
        self.predicateRegistryVersion = KnowledgePredicate.registryVersion
        self.objectEntityID = objectEntityID
        self.valueData = valueData
        self.modalityRaw = modality.rawValue
        self.polarityRaw = polarity.rawValue
        self.claimKindRaw = claimKind.rawValue
        self.authorityStatusRaw = authorityStatus.rawValue
        self.confidenceBandRaw = confidenceBand.rawValue
        self.reviewStateRaw = reviewState.rawValue
        self.validFromText = validFrom?.text
        self.validFromPrecisionRaw = validFrom?.precision.rawValue
        self.validToText = validTo?.text
        self.validToPrecisionRaw = validTo?.precision.rawValue
        self.recordedAt = recordedAt
        self.retractedAt = nil
        self.sourceMeetingID = sourceMeetingID
        self.contextID = contextID
        self.revisionID = revisionID
        self.extractorVersion = extractorVersion
    }
}

/// One validated citation (`KnowledgeEvidenceValidator`) of an assertion.
@Model
final class KnowledgeEvidence {
    #Index<KnowledgeEvidence>([\.assertionID], [\.meetingID, \.transcriptFingerprint])
    @Attribute(.unique) var id: UUID
    var assertionID: UUID
    var meetingID: UUID
    var recordingID: UUID?
    /// The transcript revision the segments belong to (K1.3).
    var transcriptFingerprint: String
    /// JSON `[String]`: the cited segment anchors, contiguous, in transcript order.
    var segmentIDsData: Data
    var quote: String
    /// SHA-256 of the normalized quote, hex.
    var quoteHash: String
    var startMs: Int
    var endMs: Int
    /// False once the cited transcript revision is gone: the evidence is kept
    /// as a record but can no longer be verified (spec §12.1).
    var isAvailable: Bool
    var createdAt: Date

    // swiftlint:disable:next function_parameter_count
    init(
        id: UUID = UUID(),
        assertionID: UUID,
        meetingID: UUID,
        recordingID: UUID? = nil,
        transcriptFingerprint: String,
        segmentIDsData: Data,
        quote: String,
        quoteHash: String,
        startMs: Int,
        endMs: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.assertionID = assertionID
        self.meetingID = meetingID
        self.recordingID = recordingID
        self.transcriptFingerprint = transcriptFingerprint
        self.segmentIDsData = segmentIDsData
        self.quote = quote
        self.quoteHash = quoteHash
        self.startMs = startMs
        self.endMs = endMs
        self.isAvailable = true
        self.createdAt = createdAt
    }
}

/// A dated change states and timelines are projected from.
@Model
final class KnowledgeEvent {
    #Index<KnowledgeEvent>([\.entityID], [\.sourceMeetingID])
    @Attribute(.unique) var id: UUID
    var entityID: UUID
    var kindRaw: String
    /// The assertion that states the change, when there is one.
    var assertionID: UUID?
    /// When it happened, at its stated precision; nil when unknown.
    var occurredAtText: String?
    var occurredPrecisionRaw: String?
    var recordedAt: Date
    var sourceMeetingID: UUID
    var contextID: UUID?
    var revisionID: UUID

    init(
        id: UUID = UUID(),
        entityID: UUID,
        kind: KnowledgeEventKind,
        assertionID: UUID? = nil,
        occurredAt: KnowledgeTemporalValue? = nil,
        recordedAt: Date = Date(),
        sourceMeetingID: UUID,
        contextID: UUID? = nil,
        revisionID: UUID
    ) {
        self.id = id
        self.entityID = entityID
        self.kindRaw = kind.rawValue
        self.assertionID = assertionID
        self.occurredAtText = occurredAt?.text
        self.occurredPrecisionRaw = occurredAt?.precision.rawValue
        self.recordedAt = recordedAt
        self.sourceMeetingID = sourceMeetingID
        self.contextID = contextID
        self.revisionID = revisionID
    }
}

/// A graph edge, derived from a relational assertion and never stored as an
/// independent fact (spec §5.2).
@Model
final class KnowledgeRelation {
    #Index<KnowledgeRelation>([\.subjectEntityID], [\.objectEntityID], [\.assertionID])
    @Attribute(.unique) var id: UUID
    var subjectEntityID: UUID
    var predicateRaw: String
    var objectEntityID: UUID
    var assertionID: UUID
    /// Inferred edges are hidden by default (K4).
    var isInferred: Bool
    var revisionID: UUID

    init(
        id: UUID = UUID(),
        subjectEntityID: UUID,
        predicate: KnowledgePredicate,
        objectEntityID: UUID,
        assertionID: UUID,
        isInferred: Bool = false,
        revisionID: UUID
    ) {
        self.id = id
        self.subjectEntityID = subjectEntityID
        self.predicateRaw = predicate.rawValue
        self.objectEntityID = objectEntityID
        self.assertionID = assertionID
        self.isInferred = isInferred
        self.revisionID = revisionID
    }
}

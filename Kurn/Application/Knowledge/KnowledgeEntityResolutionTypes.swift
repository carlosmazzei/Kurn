import Foundation
import KurnCore

/// A scope label is not an ACL. The host must explicitly authorize every
/// meeting whose entity identities may be read or changed.
struct KnowledgeEntityResolutionAuthorization: Sendable {
    let extraction: KnowledgeExtractionAuthorization
    let meetingIDs: Set<UUID>
}

struct KnowledgeEntityResolutionSnapshot: Sendable {
    struct Source: Codable, Equatable, Sendable {
        let meetingID: UUID
        let fingerprint: String
    }
    let scope: String
    let revision: Int
    let policyRevisionKey: String
    let sources: [Source]
    let entities: [KnowledgeEntityResolutionValue]
    let redirects: [UUID: KnowledgeEntityRedirect]
    let isTruncated: Bool
}

struct KnowledgeEntityMergeRequest: Sendable {
    let operationID: UUID
    let sourceID: UUID
    let targetID: UUID
    let snapshot: KnowledgeEntityResolutionSnapshot
    var candidateReviewID: UUID?
}

struct KnowledgeEntityMergeReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let sourceID: UUID
    let targetID: UUID
    let revisionID: UUID
    let revision: Int
    let isUndo: Bool
}

struct KnowledgeEntityResolutionSummary: Codable {
    let profile: KnowledgeEntityResolutionProfile
    var reviewCount = 0
    var poolTruncated = false
    var reviewLimitReached = false
}

struct KnowledgeEntityReviewPayload: Codable {
    var version = 1
    var candidate: Candidate?
    var merge: Merge?
    var resolvedByOperationID: UUID?

    struct Candidate: Codable {
        let scope: String
        let source: KnowledgeEntityResolutionSnapshot.Source
        let policyRevisionKey: String
        let sourceID: UUID
        let match: KnowledgeEntityResolutionMatch
        let profile: KnowledgeEntityResolutionProfile
    }
    struct Merge: Codable {
        let scope: String
        let sources: [KnowledgeEntityResolutionSnapshot.Source]
        let policyRevisionKey: String
        let requestedTargetID: UUID
        let candidateReviewID: UUID?
        let applied: KnowledgeEntityMergeReceipt
        var undone: KnowledgeEntityMergeReceipt?
        var undoPolicyRevisionKey: String?
    }
}

enum KnowledgeEntityStoreError: String, Error {
    case scopeDenied = "entity_scope_denied"
    case staleSnapshot = "entity_snapshot_stale"
    case invalidReview = "invalid_entity_review"
    case unreadablePayload = "unreadable_entity_payload"
    case unsupportedPayload = "unsupported_entity_payload"
    case inactiveEntity = "inactive_entity"
    case alreadyMerged = "entity_already_merged"
    case mergeChanged = "entity_merge_changed"
    case operationUndone = "entity_operation_undone"
}

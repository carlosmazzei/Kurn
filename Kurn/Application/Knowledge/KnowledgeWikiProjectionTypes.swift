import Foundation
import KurnCore

/// Scope names never grant access. The host supplies a fresh source-ID ACL on
/// every read/publication; deterministic projections require no provider.
struct KnowledgeSourceAuthorization: Sendable {
    var featureEnabled: Bool
    var meetingIDs: Set<UUID>
    var policies: [KnowledgeProcessingPolicy]
    var sourceClassifications: [KnowledgeClassification]

    var extraction: KnowledgeExtractionAuthorization {
        KnowledgeExtractionAuthorization(featureEnabled: featureEnabled, policies: policies, sourceClassifications: sourceClassifications)
    }

    func authorize(classifications: [KnowledgeClassification], operation: KnowledgeOperation = .pageNarrative) throws {
        let request = KnowledgeProcessingRequest(operation: operation, destination: .onDevice,
            sourceClassifications: sourceClassifications + classifications, userConsentedToRemote: false)
        guard KnowledgePolicyEvaluator.evaluate(request, under: policies, featureEnabled: featureEnabled).isAllowed else {
            throw KnowledgeWikiStoreError.scopeDenied
        }
    }
}

typealias KnowledgeWikiAuthorization = KnowledgeSourceAuthorization

struct KnowledgeWikiProjectionSnapshot: Sendable {
    let scope: String
    let policyRevisionKey: String
    let sources: [KnowledgeEntityResolutionSnapshot.Source]
    let wiki: KnowledgeWikiSnapshot
}

struct KnowledgeWikiProjection: Codable, Equatable, Sendable {
    var version = 1
    let scope: String
    let policyRevisionKey: String
    let sources: [KnowledgeEntityResolutionSnapshot.Source]
    let snapshot: KnowledgeWikiSnapshot
    let pages: [KnowledgeWikiPage]
}

enum KnowledgeWikiStoreError: String, Error, Sendable {
    case scopeDenied = "wiki_scope_denied"
    case staleSnapshot = "wiki_snapshot_stale"
    case invalidCanonical = "wiki_invalid_canonical"
    case unreadableProjection = "wiki_unreadable_projection"
    case unsupportedProjection = "wiki_unsupported_projection"
}

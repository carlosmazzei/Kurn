//
//  KnowledgeProcessingPolicy.swift
//  KurnCore
//
//  Where Knowledge Engine work may run, decided before anything is retrieved,
//  put into a prompt, sent off the device or exported (CLAUDE.md, "Knowledge
//  Engine decisions"). The default denies every egress: knowledge is compiled
//  on the device unless the workspace's policy names a remote destination,
//  allows the operation for the classification of every source involved, and
//  the user consented to that operation. Corporate authorization is checked
//  before personal consent because consent never substitutes for it.
//
//  The policy that applies to one piece of work is the intersection of every
//  policy in play — the workspace's, each source's and each context's — so a
//  derivative (an embedding, a page, an answer, an export) inherits the
//  strictest restriction of the evidence it was built from. Pure value logic,
//  tested on Linux; the app persists the policies and calls `evaluate` at each
//  boundary.
//

import Foundation

/// A Knowledge Engine operation that may need a model, the network or a file
/// leaving the device.
public enum KnowledgeOperation: String, Codable, Sendable, CaseIterable {
    /// Extracting entities, assertions and events from a transcript.
    case extraction
    /// Writing the optional narrative of a global wiki page.
    case pageNarrative
    /// The optional semantic review of the maintenance lint.
    case semanticLint
    /// Computing embeddings for knowledge documents.
    case embedding
    /// Answering a question over knowledge (Ask).
    case answerSynthesis
    /// Writing an export bundle.
    case export
}

/// Where an operation runs.
public enum KnowledgeDestination: Hashable, Codable, Sendable {
    /// On this device; nothing leaves it.
    case onDevice
    /// A configured remote provider, by its provider ID.
    case remote(providerID: String)
}

/// How sensitive a source is, from least to most restricted. A derivative
/// takes the most restricted classification of its sources.
public enum KnowledgeClassification: Int, Codable, Sendable, CaseIterable, Comparable {
    case unrestricted = 0
    case `internal` = 1
    case confidential = 2
    case restricted = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The classification a derivative of `sources` inherits: the most
    /// restricted one, or nil when there is no source at all.
    public static func inherited(from sources: some Sequence<KnowledgeClassification>) -> KnowledgeClassification? {
        sources.max()
    }
}

/// One processing policy: the workspace's, a source's or a context's.
public struct KnowledgeProcessingPolicy: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Incremented on every change; part of every cache key built under it.
    public var revision: Int
    /// Remote providers this policy authorizes. Empty means none: on-device only.
    public var allowedRemoteProviderIDs: Set<String>
    public var allowedOperations: Set<KnowledgeOperation>
    /// The most restricted classification that may be sent to an authorized
    /// remote provider; nil means no classification may leave the device.
    public var maxRemoteClassification: KnowledgeClassification?
    public var exportAllowed: Bool

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        allowedRemoteProviderIDs: Set<String> = [],
        allowedOperations: Set<KnowledgeOperation> = KnowledgeProcessingPolicy.onDeviceOperations,
        maxRemoteClassification: KnowledgeClassification? = nil,
        exportAllowed: Bool = false
    ) {
        self.id = id
        self.revision = revision
        self.allowedRemoteProviderIDs = allowedRemoteProviderIDs
        self.allowedOperations = allowedOperations
        self.maxRemoteClassification = maxRemoteClassification
        self.exportAllowed = exportAllowed
    }

    /// Every operation except export, which is off until a policy allows it.
    public static let onDeviceOperations = Set(KnowledgeOperation.allCases).subtracting([.export])

    /// The default for a new workspace: work stays on the device, nothing is exported.
    public static func defaultDeny(id: UUID = UUID()) -> KnowledgeProcessingPolicy {
        KnowledgeProcessingPolicy(id: id)
    }

    /// What both policies allow. Never wider than either.
    public func intersection(_ other: KnowledgeProcessingPolicy) -> KnowledgeProcessingPolicy {
        let ceiling: KnowledgeClassification? = switch (maxRemoteClassification, other.maxRemoteClassification) {
        case let (lhs?, rhs?): min(lhs, rhs)
        default: nil
        }
        return KnowledgeProcessingPolicy(
            id: id,
            revision: revision,
            allowedRemoteProviderIDs: allowedRemoteProviderIDs.intersection(other.allowedRemoteProviderIDs),
            allowedOperations: allowedOperations.intersection(other.allowedOperations),
            maxRemoteClassification: ceiling,
            exportAllowed: exportAllowed && other.exportAllowed
        )
    }
}

/// One piece of work to authorize.
public struct KnowledgeProcessingRequest: Sendable, Hashable {
    public var operation: KnowledgeOperation
    public var destination: KnowledgeDestination
    /// The classification of every source the work reads.
    public var sourceClassifications: [KnowledgeClassification]
    /// Whether the user consented to this operation going to a remote provider.
    public var userConsentedToRemote: Bool

    public init(
        operation: KnowledgeOperation,
        destination: KnowledgeDestination,
        sourceClassifications: [KnowledgeClassification],
        userConsentedToRemote: Bool = false
    ) {
        self.operation = operation
        self.destination = destination
        self.sourceClassifications = sourceClassifications
        self.userConsentedToRemote = userConsentedToRemote
    }
}

/// Why a request was refused. Fixed vocabulary, safe to log publicly.
public enum KnowledgePolicyDenial: String, Codable, Sendable, CaseIterable {
    case featureDisabled = "feature_disabled"
    case noPolicy = "no_policy"
    case noSources = "no_sources"
    case operationNotAllowed = "operation_not_allowed"
    case exportNotAllowed = "export_not_allowed"
    case destinationNotAuthorized = "destination_not_authorized"
    case classificationTooHigh = "classification_too_high"
    case consentMissing = "consent_missing"
}

public enum KnowledgePolicyDecision: Sendable, Hashable {
    case allowed
    case denied(KnowledgePolicyDenial)

    public var isAllowed: Bool { self == .allowed }
}

public enum KnowledgePolicyEvaluator {
    /// Decides `request` under the intersection of `policies`. Checks run from
    /// the broadest refusal to the narrowest, and corporate authorization
    /// (destination, classification) before the user's consent.
    public static func evaluate(
        _ request: KnowledgeProcessingRequest,
        under policies: [KnowledgeProcessingPolicy],
        featureEnabled: Bool
    ) -> KnowledgePolicyDecision {
        guard featureEnabled else { return .denied(.featureDisabled) }
        guard let effective = effectivePolicy(policies) else { return .denied(.noPolicy) }
        guard let classification = KnowledgeClassification.inherited(from: request.sourceClassifications) else {
            return .denied(.noSources)
        }
        guard effective.allowedOperations.contains(request.operation) else {
            return .denied(.operationNotAllowed)
        }
        if request.operation == .export, !effective.exportAllowed {
            return .denied(.exportNotAllowed)
        }
        guard case let .remote(providerID) = request.destination else { return .allowed }
        guard effective.allowedRemoteProviderIDs.contains(providerID) else {
            return .denied(.destinationNotAuthorized)
        }
        guard let ceiling = effective.maxRemoteClassification, classification <= ceiling else {
            return .denied(.classificationTooHigh)
        }
        guard request.userConsentedToRemote else { return .denied(.consentMissing) }
        return .allowed
    }

    /// The intersection of `policies`, or nil when there are none — an absent
    /// policy is a refusal, never an implicit allowance.
    public static func effectivePolicy(_ policies: [KnowledgeProcessingPolicy]) -> KnowledgeProcessingPolicy? {
        guard let first = policies.first else { return nil }
        return policies.dropFirst().reduce(first) { $0.intersection($1) }
    }

    /// A stable key naming every policy revision in play, for cache keys:
    /// a cached result is reusable only under exactly the same revisions.
    public static func revisionKey(_ policies: [KnowledgeProcessingPolicy]) -> String {
        Set(policies.map { "\($0.id.uuidString.lowercased()):\($0.revision)" })
            .sorted()
            .joined(separator: ",")
    }
}

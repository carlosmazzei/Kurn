//
//  KnowledgeVocabulary.swift
//  KurnCore
//
//  The closed vocabularies of the Knowledge Engine's canonical layer
//  (CLAUDE.md, "Knowledge Engine decisions"). Raw values are persisted and
//  exchanged with the extraction model, so they never change once shipped: a
//  new term is a new case, and an unknown term from a model is rejected or
//  queued for review, never stored as a free string.
//

import Foundation

/// What an entity is. An entity has a stable identity; it is not a claim
/// that something exists in the world.
public enum KnowledgeEntityKind: String, Codable, Sendable, CaseIterable {
    case topic, project, initiative, person, team, organization, system, technology
    case decisionThread, actionItem, risk, question, metric

    /// Kinds that name an actor: who can own, be assigned, forecast or attribute.
    public static let actors: Set<KnowledgeEntityKind> = [.person, .team, .organization]
}

/// How an assertion was put forward. A report is not a decision, a proposal
/// is not an approval.
public enum KnowledgeModality: String, Codable, Sendable, CaseIterable {
    case reported, proposed, agreed, disputed, hypothetical, observed, inferred
}

public enum KnowledgePolarity: String, Codable, Sendable, CaseIterable {
    case positive, negative
}

/// Where a machine-made assertion stands with the user.
public enum KnowledgeReviewState: String, Codable, Sendable, CaseIterable {
    case machineExtracted, userConfirmed, disputed, rejected, invalidated

    /// Whether the assertion may appear as current knowledge.
    public var isVisible: Bool {
        switch self {
        case .machineExtracted, .userConfirmed, .disputed: true
        case .rejected, .invalidated: false
        }
    }
}

/// A qualitative band, not a calibrated probability.
public enum KnowledgeConfidenceBand: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

/// The nature of a claim (spec §20.1). A forecast is never promoted to a fact,
/// nor a suggestion to a decision, by classification alone.
public enum KnowledgeClaimKind: String, Codable, Sendable, CaseIterable {
    case analystForecast, vendorClaim, externalObservation, researchFinding, personalReflection
    case internalHypothesis, internalProposal, internalDecision, internalStatusReport
    case commitment, question, unknown

    /// Claims made by someone outside the workspace's organization.
    public var isExternal: Bool {
        switch self {
        case .analystForecast, .vendorClaim, .externalObservation, .researchFinding: true
        default: false
        }
    }
}

/// How far a claim has been established. Internal confirmation does not
/// prove universal truth.
public enum KnowledgeAuthorityStatus: String, Codable, Sendable, CaseIterable {
    case attributed, unverified, corroborated, internallyConfirmed, disputed, rejected
}

/// The kind of occasion a source was recorded at. `unknown` is valid and
/// reviewable — every meeting recorded before contexts existed has it.
public enum KnowledgeContextKind: String, Codable, Sendable, CaseIterable {
    case internalMeeting, conference, conferenceSession, executiveBriefing, vendorDiscussion
    case executiveConversation, workshop, personalReflection, other, unknown
}

/// An organization's part in a context. Presence never implies employment.
public enum KnowledgeOrganizationRole: String, Codable, Sendable, CaseIterable {
    case owner, host, speakerAffiliation, vendor, analyst, partner, mentioned
}

import Foundation

/// A host-authorized, evidence-checked projection input. It is never evidence
/// itself and contains no provider or persistence dependencies.
public struct KnowledgeWikiSnapshot: Codable, Equatable, Sendable {
    public let revision: Int
    public let entities: [Entity]
    public let facts: [Fact]

    public init(revision: Int, entities: [Entity], facts: [Fact]) {
        self.revision = revision
        self.entities = entities
        self.facts = facts
    }

    public struct Entity: Codable, Equatable, Sendable {
        public let id: UUID
        public let kind: KnowledgeEntityKind
        public let name: String
        public let aliases: [String]
        public let targetID: UUID?

        public init(id: UUID, kind: KnowledgeEntityKind, name: String, aliases: [String] = [], targetID: UUID? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.aliases = aliases
            self.targetID = targetID
        }
    }

    public struct Fact: Codable, Equatable, Sendable {
        public let id: UUID
        public let subjectID: UUID
        public let predicate: KnowledgePredicate
        public let objectID: UUID?
        public let value: KnowledgeTypedValue?
        public let qualifiers: Qualifiers
        public let source: Source

        // swiftlint:disable:next function_parameter_count
        public init(id: UUID, subjectID: UUID, predicate: KnowledgePredicate, objectID: UUID? = nil,
                    value: KnowledgeTypedValue? = nil, qualifiers: Qualifiers, source: Source) {
            self.id = id
            self.subjectID = subjectID
            self.predicate = predicate
            self.objectID = objectID
            self.value = value
            self.qualifiers = qualifiers
            self.source = source
        }
    }

    public struct Qualifiers: Codable, Equatable, Sendable {
        public let modality: KnowledgeModality
        public let polarity: KnowledgePolarity
        public let claimKind: KnowledgeClaimKind
        public let authority: KnowledgeAuthorityStatus
        public let confidence: KnowledgeConfidenceBand
        public let review: KnowledgeReviewState
        public let validFrom: KnowledgeTemporalValue?
        public let validTo: KnowledgeTemporalValue?

        // swiftlint:disable:next function_parameter_count
        public init(modality: KnowledgeModality, polarity: KnowledgePolarity, claimKind: KnowledgeClaimKind,
                    authority: KnowledgeAuthorityStatus, confidence: KnowledgeConfidenceBand, review: KnowledgeReviewState,
                    validFrom: KnowledgeTemporalValue? = nil, validTo: KnowledgeTemporalValue? = nil) {
            self.modality = modality
            self.polarity = polarity
            self.claimKind = claimKind
            self.authority = authority
            self.confidence = confidence
            self.review = review
            self.validFrom = validFrom
            self.validTo = validTo
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public let meetingID: UUID
        /// Transaction time: when the store learned the claim (its meeting was compiled into knowledge).
        public let recordedAt: Date
        /// Source time (K7.1): the date of the recording the claim's evidence quotes, i.e. when it was said.
        /// Nil when the recording is not known; a stored snapshot from before it existed decodes with nil.
        public let observedAt: Date?
        public let evidence: [Evidence]

        public init(meetingID: UUID, recordedAt: Date, observedAt: Date? = nil, evidence: [Evidence]) {
            self.meetingID = meetingID
            self.recordedAt = recordedAt
            self.observedAt = observedAt
            self.evidence = evidence
        }
    }

    public struct Evidence: Codable, Equatable, Sendable {
        public let id: UUID
        public let recordingID: UUID
        public let segmentIDs: [String]
        public let quote: String
        public let startMs: Int
        public let endMs: Int
        public let attributedSpeaker: String

        // swiftlint:disable:next function_parameter_count
        public init(id: UUID, recordingID: UUID, segmentIDs: [String], quote: String,
                    startMs: Int, endMs: Int, attributedSpeaker: String) {
            self.id = id
            self.recordingID = recordingID
            self.segmentIDs = segmentIDs
            self.quote = quote
            self.startMs = startMs
            self.endMs = endMs
            self.attributedSpeaker = attributedSpeaker
        }
    }
}

/// Optional model output is plain text plus host-resolved assertion IDs.
/// Citation validation establishes reference integrity, not semantic entailment.
public struct KnowledgeWikiNarrative: Codable, Equatable, Sendable {
    public let version: Int
    public let entityID: UUID
    public let paragraphs: [Paragraph]

    public init(version: Int = 1, entityID: UUID, paragraphs: [Paragraph]) {
        self.version = version
        self.entityID = entityID
        self.paragraphs = paragraphs
    }

    public struct Paragraph: Codable, Equatable, Sendable {
        public let text: String
        public let assertionIDs: [UUID]

        public init(text: String, assertionIDs: [UUID]) {
            self.text = text
            self.assertionIDs = assertionIDs
        }
    }
}

public enum KnowledgeWikiProjectionError: String, Error, Sendable {
    case invalidSnapshot = "wiki_invalid_snapshot"
    case projectionLimit = "wiki_projection_limit"
    case invalidNarrative = "wiki_invalid_narrative"
    case unsupportedNarrative = "wiki_unsupported_narrative"
}

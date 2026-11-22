import Foundation

/// Versioned model output, never a store write. References are local to one
/// response; the host namespaces them per pass before resolution (K1.7).
public struct KnowledgeExtraction: Codable, Sendable {
    public let version: Int
    public let entities: [Entity]
    public let assertions: [Assertion]
    public let events: [Event]
    /// Explicitly inspected anchors, including segments yielding no assertions.
    public let examinedSegmentIDs: [String]

    public struct Entity: Codable, Sendable {
        public let ref: String
        public let kind: KnowledgeEntityKind
        public let name: String
        public let aliases: [String]
    }

    public struct Assertion: Codable, Sendable {
        public let ref: String
        public let subject: String
        public let predicate: KnowledgePredicate
        public let object: String?
        public let value: KnowledgeTypedValue?
        public let modality: KnowledgeModality
        public let polarity: KnowledgePolarity
        public let claimKind: KnowledgeClaimKind
        public let authorityStatus: KnowledgeAuthorityStatus
        public let confidence: KnowledgeConfidenceBand
        /// Attribution is an original segment anchor, never an invented person.
        public let attributedToSegmentID: String
        public let validFrom: StatedDate?
        public let validTo: StatedDate?
        public let evidence: [Citation]
    }

    public struct StatedDate: Codable, Sendable {
        public let text: String
        public let precision: KnowledgeTemporalPrecision
        public var parsed: KnowledgeTemporalValue? { KnowledgeTemporalValue(text: text, precision: precision) }
    }

    public struct Citation: Codable, Sendable {
        public let segmentIDs: [String]
        public let quote: String
        public let startMs: Int?
        public let endMs: Int?
        public var claim: KnowledgeEvidenceClaim {
            KnowledgeEvidenceClaim(segmentIDs: segmentIDs, quote: quote, startMs: startMs, endMs: endMs)
        }
    }

    public struct Event: Codable, Sendable {
        public let ref: String
        public let entity: String
        public let assertion: String
        public let kind: KnowledgeEventKind
        public let occurredAt: StatedDate?
    }
}

/// Content-free errors: do not log provider replies or decoding diagnostics.
public enum KnowledgeExtractionError: String, Error, Sendable {
    case invalidJSON = "invalid_json"
    case invalidSchema = "invalid_schema"
    case unsupportedVersion = "unsupported_version"
    case duplicateReference = "duplicate_reference"
    case unknownReference = "unknown_reference"
    case invalidAssertion = "invalid_assertion"
    case invalidEvidence = "invalid_evidence"
    case invalidDate = "invalid_date"
    case invalidCoverage = "invalid_coverage"
    case responseTooLarge = "response_too_large"
}

extension KnowledgeExtraction {
    /// Strict decoding with partial acceptance (user decision, 2026-11-22).
    /// Whole-pass rejections — the reply cannot be trusted: unknown fields or
    /// vocabularies, duplicate or unresolved refs, coverage outside the
    /// supplied segments, and any fabricated, stitched or misattributed quote.
    /// Discarded individually — the fact is well-formed and cited but breaks a
    /// domain rule: a predicate/kind/value mismatch, an inferred modality where
    /// an explicit statement is required, an unsupported authority status, an
    /// invalid date, and events that are inconsistent or point at a discarded
    /// assertion. Use `decodeReport` to learn how many were dropped.
    public static func decode(_ data: Data, segments: [KnowledgeSourceSegment]) throws -> Self {
        try decodeReport(data, segments: segments).extraction
    }

    public static func decodeReport(_ data: Data, segments: [KnowledgeSourceSegment]) throws
        -> (extraction: Self, discardedAssertions: Int, discardedEvents: Int) {
        guard data.count <= 2_000_000 else { throw KnowledgeExtractionError.responseTooLarge }
        do {
            try KnowledgeExtractionShape.check(data)
            let result = try JSONDecoder().decode(Self.self, from: data)
            return try result.validated(segments: segments)
        } catch let error as KnowledgeExtractionError {
            throw error
        } catch {
            throw KnowledgeExtractionError.invalidSchema
        }
    }

    private func validated(segments: [KnowledgeSourceSegment]) throws
        -> (extraction: Self, discardedAssertions: Int, discardedEvents: Int) {
        guard version == 1 else { throw KnowledgeExtractionError.unsupportedVersion }
        let refs = entities.map(\.ref) + assertions.map(\.ref) + events.map(\.ref)
        guard refs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(refs).count == refs.count else {
            throw KnowledgeExtractionError.duplicateReference
        }
        let known = Set(segments.map(\.id))
        let examined = Set(examinedSegmentIDs)
        guard known.count == segments.count, examined.count == examinedSegmentIDs.count, examined.isSubset(of: known) else {
            throw KnowledgeExtractionError.invalidCoverage
        }
        let entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.ref, $0) })
        let assertionsByID = Dictionary(uniqueKeysWithValues: assertions.map { ($0.ref, $0) })
        guard entities.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw KnowledgeExtractionError.invalidSchema
        }
        let validator = KnowledgeEvidenceValidator(segments: segments)
        var kept: [Assertion] = []
        for assertion in assertions {
            guard let subject = entitiesByID[assertion.subject],
                  assertion.object == nil || entitiesByID[assertion.object ?? ""] != nil else {
                throw KnowledgeExtractionError.unknownReference
            }
            let cited = Set(assertion.evidence.flatMap(\.segmentIDs))
            guard !assertion.evidence.isEmpty, cited.isSubset(of: examined), cited.contains(assertion.attributedToSegmentID) else {
                throw KnowledgeExtractionError.invalidEvidence
            }
            for evidence in assertion.evidence {
                guard case .success = validator.validate(evidence.claim) else { throw KnowledgeExtractionError.invalidEvidence }
            }
            let ruleHolds = assertion.predicate.violation(subjectKind: subject.kind,
                objectKind: assertion.object.flatMap { entitiesByID[$0]?.kind }, value: assertion.value) == nil
                && !(assertion.predicate.rule.requiresExplicitStatement && assertion.modality == .inferred)
                && [.attributed, .unverified, .disputed].contains(assertion.authorityStatus)
                && (try? Self.checkDates(from: assertion.validFrom, to: assertion.validTo)) != nil
            if ruleHolds { kept.append(assertion) }
        }
        let keptRefs = Set(kept.map(\.ref))
        var keptEvents: [Event] = []
        for event in events {
            guard let assertion = assertionsByID[event.assertion] else { throw KnowledgeExtractionError.unknownReference }
            guard keptRefs.contains(assertion.ref),
                  event.entity == (event.kind == .superseded ? assertion.object : assertion.subject),
                  (try? Self.checkDates(from: event.occurredAt, to: nil)) != nil,
                  Self.eventMatches(event.kind, assertion) else { continue }
            keptEvents.append(event)
        }
        // Entities only some dropped fact used stay: an entity alone asserts nothing.
        let extraction = KnowledgeExtraction(version: version, entities: entities, assertions: kept,
                                             events: keptEvents, examinedSegmentIDs: examinedSegmentIDs)
        return (extraction, assertions.count - kept.count, events.count - keptEvents.count)
    }

    private static func eventMatches(_ kind: KnowledgeEventKind, _ assertion: Assertion) -> Bool {
        switch kind {
        case .created: return true
        case .statusChanged: return assertion.predicate == .hasStatus
        case .assigned: return assertion.predicate == .assignedTo
        case .dueDateChanged: return assertion.predicate == .dueOn
        case .metricReported: return assertion.predicate == .reportsMetric
        case .superseded: return assertion.predicate == .supersedes
        case .reopened: return assertion.predicate == .hasStatus && assertion.value == .enumeration("reopened")
        case .merged, .contextLinked: return false
        }
    }

    private static func checkDates(from: StatedDate?, to: StatedDate?) throws {
        guard from == nil || from?.parsed != nil, to == nil || to?.parsed != nil else { throw KnowledgeExtractionError.invalidDate }
        // Different precisions do not establish an exact ordering; the temporal
        // reducer handles possible/definite intervals. Equal-precision intervals
        // are half-open and must have positive width.
        if let from, let to, from.precision == to.precision, from.text >= to.text {
            throw KnowledgeExtractionError.invalidDate
        }
    }
}

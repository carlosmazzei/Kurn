//
//  KnowledgePredicate.swift
//  KurnCore
//
//  The closed, versioned predicate vocabulary and its registry (spec §5.2 and
//  §20.3): for each predicate, which entity kinds may be its subject, whether
//  its object is an entity (of which kinds) or a typed value (of which types),
//  and whether it is symmetric. A predicate a model invents is not a predicate:
//  it becomes a candidate for review, never a new schema. Relations in the
//  graph are derived from relational assertions validated here, never stored
//  as independent facts.
//

import Foundation

public enum KnowledgePredicate: String, Codable, Sendable, CaseIterable {
    // §5.2
    case relatesTo, partOf, owns, assignedTo, dependsOn, blocks, supports, opposes
    case proposes, approves, rejects, supersedes, contradicts, resolves, mentions
    case reportsMetric, hasStatus, dueOn
    // §20.3
    case presentedAt, hostedBy, attributedTo, discusses, evaluates, references
    case inspiredBy, adoptedIn, challenges, forecastFor

    /// The registry version; bump it whenever a case or a rule changes.
    public static let registryVersion = 1

    public var rule: KnowledgePredicateRule {
        KnowledgePredicateRule.rule(for: self)
    }
}

/// What a predicate's object may be.
public enum KnowledgePredicateObject: Hashable, Sendable {
    /// Another entity; nil kinds means any kind.
    case entity(Set<KnowledgeEntityKind>?)
    /// A typed value of one of these types.
    case value(Set<KnowledgeValueType>)
}

public struct KnowledgePredicateRule: Hashable, Sendable {
    /// Allowed subject kinds; nil means any kind.
    public let subjectKinds: Set<KnowledgeEntityKind>?
    public let object: KnowledgePredicateObject
    /// `a p b` implies `b p a`.
    public let isSymmetric: Bool
    /// Never accepted on inference alone: it needs an explicit statement or
    /// a human's confirmation (ownership, influence, adoption).
    public let requiresExplicitStatement: Bool

    static func rule(for predicate: KnowledgePredicate) -> KnowledgePredicateRule {
        let actors = KnowledgeEntityKind.actors
        switch predicate {
        case .relatesTo, .contradicts:
            return KnowledgePredicateRule(subjectKinds: nil, object: .entity(nil), isSymmetric: true, requiresExplicitStatement: false)
        case .owns:
            return KnowledgePredicateRule(subjectKinds: actors, object: .entity(nil), isSymmetric: false, requiresExplicitStatement: true)
        case .assignedTo:
            return KnowledgePredicateRule(
                subjectKinds: [.actionItem, .risk, .question, .project, .initiative, .decisionThread],
                object: .entity(actors), isSymmetric: false, requiresExplicitStatement: true
            )
        case .resolves:
            return KnowledgePredicateRule(
                subjectKinds: nil, object: .entity([.question, .risk, .decisionThread, .actionItem]),
                isSymmetric: false, requiresExplicitStatement: false
            )
        case .forecastFor:
            return KnowledgePredicateRule(subjectKinds: actors, object: .entity(nil), isSymmetric: false, requiresExplicitStatement: false)
        case .inspiredBy, .adoptedIn:
            return KnowledgePredicateRule(subjectKinds: nil, object: .entity(nil), isSymmetric: false, requiresExplicitStatement: true)
        case .reportsMetric:
            return KnowledgePredicateRule(subjectKinds: nil, object: .value([.number, .string]), isSymmetric: false, requiresExplicitStatement: false)
        case .hasStatus:
            return KnowledgePredicateRule(subjectKinds: nil, object: .value([.enumeration]), isSymmetric: false, requiresExplicitStatement: false)
        case .dueOn:
            return KnowledgePredicateRule(
                subjectKinds: [.actionItem, .project, .initiative, .risk, .question, .decisionThread, .metric],
                object: .value([.date]), isSymmetric: false, requiresExplicitStatement: false
            )
        case .partOf, .dependsOn, .blocks, .supports, .opposes, .proposes, .approves, .rejects,
             .supersedes, .mentions, .presentedAt, .hostedBy, .attributedTo, .discusses,
             .evaluates, .references, .challenges:
            return KnowledgePredicateRule(subjectKinds: nil, object: .entity(nil), isSymmetric: false, requiresExplicitStatement: false)
        }
    }

    /// Why a subject/object pair breaks this rule, or nil when it fits.
    public func violation(
        subjectKind: KnowledgeEntityKind,
        objectKind: KnowledgeEntityKind?,
        valueType: KnowledgeValueType?
    ) -> KnowledgeSchemaViolation? {
        if let subjectKinds, !subjectKinds.contains(subjectKind) { return .subjectKindNotAllowed }
        switch object {
        case let .entity(kinds):
            guard valueType == nil else { return .valueWhereEntityExpected }
            guard let objectKind else { return .missingObject }
            if let kinds, !kinds.contains(objectKind) { return .objectKindNotAllowed }
        case let .value(types):
            guard objectKind == nil else { return .entityWhereValueExpected }
            guard let valueType else { return .missingObject }
            if !types.contains(valueType) { return .valueTypeNotAllowed }
        }
        return nil
    }
}

/// Why an assertion's shape was rejected. Fixed vocabulary, safe to log.
public enum KnowledgeSchemaViolation: String, Codable, Sendable, CaseIterable {
    case subjectKindNotAllowed = "subject_kind_not_allowed"
    case objectKindNotAllowed = "object_kind_not_allowed"
    case valueTypeNotAllowed = "value_type_not_allowed"
    case valueWhereEntityExpected = "value_where_entity_expected"
    case entityWhereValueExpected = "entity_where_value_expected"
    case missingObject = "missing_object"
}

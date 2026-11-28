//
//  KnowledgeInference+Commitments.swift
//  KurnCore
//
//  K7.4: owner → action → due (CLAUDE.md "Knowledge derived edges (K7.4)"). An action's
//  owner and its due date are two separate stated claims; this joins them into "who has
//  to deliver by when", listing both as premises. It reads value claims, which the graph's
//  edges do not carry, so it takes the page facts. Pure and deterministic; nothing is
//  stored or written, and nothing here is evidence.
//

import Foundation

extension KnowledgeInference {
    public struct DerivedCommitment: Equatable, Sendable {
        public let ownerID: UUID
        public let actionID: UUID
        public let due: KnowledgeTemporalValue
        /// The ownership claim, then the due-date claim.
        public let premiseFactIDs: [UUID]
        /// Always `.inferred`.
        public var modality: KnowledgeModality { .inferred }
    }

    public struct CommitmentResult: Equatable, Sendable {
        public let commitments: [DerivedCommitment]
        /// The output bound cut the list short.
        public let isTruncated: Bool
    }

    /// Joins each action's established owner claims with its established due-date claims.
    /// An owner is the object of `assignedTo` (action → person) or the subject of `owns`
    /// (person → action). Several owners or several due dates give every pairing: choosing
    /// the current one is the temporal reducer's job, never this one's. Only positive,
    /// non-tentative, non-inferred claims are premises. A page repeats a relation on both
    /// entities' pages, so a claim seen twice counts once (by its ID); identities must already
    /// be resolved by the caller, as `KnowledgeStateComparison.claims(from:)` does.
    public static func deriveCommitments(from facts: [KnowledgeWikiSnapshot.Fact]) -> CommitmentResult {
        let premises = commitmentPremises(from: facts)
        return join(owners: premises.owners, dues: premises.dues)
    }

    /// The owner and due-date premises per action, each with the claim it came from.
    struct CommitmentPremises {
        var owners: [UUID: [(owner: UUID, fact: UUID)]] = [:]
        var dues: [UUID: [(due: KnowledgeTemporalValue, fact: UUID)]] = [:]
    }

    static func commitmentPremises(from facts: [KnowledgeWikiSnapshot.Fact]) -> CommitmentPremises {
        var result = CommitmentPremises()
        var seen = Set<UUID>()
        for fact in facts where isPremise(fact) && seen.insert(fact.id).inserted {
            switch fact.predicate {
            case .assignedTo:
                if let owner = fact.objectID, owner != fact.subjectID {
                    result.owners[fact.subjectID, default: []].append((owner, fact.id))
                }
            case .owns:
                if let action = fact.objectID, action != fact.subjectID {
                    result.owners[action, default: []].append((fact.subjectID, fact.id))
                }
            case .dueOn:
                if case let .date(value)? = fact.value { result.dues[fact.subjectID, default: []].append((value, fact.id)) }
            default:
                break
            }
        }
        return result
    }

    static func join(owners: [UUID: [(owner: UUID, fact: UUID)]],
                     dues: [UUID: [(due: KnowledgeTemporalValue, fact: UUID)]]) -> CommitmentResult {
        var found: [DerivedCommitment] = []
        for action in owners.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let due = dues[action] else { continue }
            let sortedOwners = (owners[action] ?? []).sorted { [$0.owner.uuidString, $0.fact.uuidString].lexicographicallyPrecedes(
                [$1.owner.uuidString, $1.fact.uuidString]) }
            let sortedDues = due.sorted { [$0.due.text, $0.fact.uuidString].lexicographicallyPrecedes([$1.due.text, $1.fact.uuidString]) }
            for owner in sortedOwners {
                for item in sortedDues {
                    if found.count >= maximumEdges { return CommitmentResult(commitments: found, isTruncated: true) }
                    found.append(DerivedCommitment(ownerID: owner.owner, actionID: action, due: item.due,
                                                   premiseFactIDs: [owner.fact, item.fact]))
                }
            }
        }
        return CommitmentResult(commitments: found, isTruncated: false)
    }

    static func isPremise(_ fact: KnowledgeWikiSnapshot.Fact) -> Bool {
        let qualifiers = fact.qualifiers
        return qualifiers.polarity == .positive && qualifiers.modality != .inferred
            && !KnowledgeTemporalReducer.tentative.contains(qualifiers.modality)
    }
}

//
//  KnowledgeInference+CurrentCommitments.swift
//  KurnCore
//
//  K7.4: the commitments that still stand. `deriveCommitments` lists every owner × date
//  pairing an action ever had; this drops the pairings whose owner or date a later
//  statement replaced, by stated start alone (CLAUDE.md "Knowledge derived edges (K7.4)").
//  Pure and deterministic; nothing here is evidence.
//

import Foundation

extension KnowledgeInference {
    /// The commitments left once a later statement replaces an earlier one. An owner claim is
    /// replaced by a claim naming a different owner whose stated start is wholly after its own
    /// (an assignment to someone else ends the earlier one); a due date likewise by a different
    /// date. This is the temporal reducer's rule for single-valued predicates, applied to the
    /// owner as well: assignments to different people are otherwise kept side by side. A claim
    /// with no stated start neither replaces nor is replaced, so an undated pairing is never
    /// narrowed away, and `recordedAt` and input order decide nothing. A pairing that survives is
    /// still a derived, review-only suggestion: it lists the same two premises.
    public static func deriveCurrentCommitments(from facts: [KnowledgeWikiSnapshot.Fact]) -> CommitmentResult {
        let premises = commitmentPremises(from: facts)
        var starts: [UUID: (lower: Date, upper: Date)] = [:]
        for fact in facts {
            if let bounds = fact.qualifiers.validFrom?.bounds { starts[fact.id] = bounds }
        }
        var owners: [UUID: [(owner: UUID, fact: UUID)]] = [:]
        for (action, items) in premises.owners {
            let replaced = replacedClaims(items.map { (statement: $0.owner.uuidString, fact: $0.fact) }, starts: starts)
            owners[action] = items.filter { !replaced.contains($0.fact) }
        }
        var dues: [UUID: [(due: KnowledgeTemporalValue, fact: UUID)]] = [:]
        for (action, items) in premises.dues {
            let replaced = replacedClaims(items.map { (statement: $0.due.text, fact: $0.fact) }, starts: starts)
            dues[action] = items.filter { !replaced.contains($0.fact) }
        }
        return join(owners: owners, dues: dues)
    }

    /// The claims some other statement replaced: one with a different statement whose stated
    /// start is wholly after this claim's own.
    private static func replacedClaims(_ items: [(statement: String, fact: UUID)],
                                       starts: [UUID: (lower: Date, upper: Date)]) -> Set<UUID> {
        var replaced = Set<UUID>()
        for item in items {
            guard let mine = starts[item.fact] else { continue }
            for other in items where other.statement != item.statement {
                guard let theirs = starts[other.fact] else { continue }
                if theirs.lower >= mine.upper {
                    replaced.insert(item.fact)
                    break
                }
            }
        }
        return replaced
    }
}
